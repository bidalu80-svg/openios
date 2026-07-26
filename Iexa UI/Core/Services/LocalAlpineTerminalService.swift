import Foundation
import os.log
import UIKit

nonisolated struct LocalAlpineExternalMount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var displayName: String
    var bookmarkData: Data
    var allowWrites: Bool
    var addedAt: Date
}

nonisolated enum LocalAlpineMountStore {
    static let maximumMounts = 10
    private static let storageKey = "localAlpine.externalMounts.v1"
    private static let workspaceFolderName = "Iexa Alpine"
    private static let sharedFolderName = "shared"

    static func loadMounts() -> [LocalAlpineExternalMount] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let mounts = try? JSONDecoder().decode([LocalAlpineExternalMount].self, from: data) else {
            return []
        }
        return Array(mounts.prefix(maximumMounts))
    }

    @discardableResult
    static func addMount(from url: URL, allowWrites: Bool = false) throws -> LocalAlpineExternalMount {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        #if os(macOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = []
        #endif
        let bookmarkData = try url.bookmarkData(
            options: bookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var mounts = loadMounts()
        guard mounts.count < maximumMounts else {
            throw NSError(
                domain: "LocalAlpineMountStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "最多只能挂载 \(maximumMounts) 个外部文件夹。"]
            )
        }

        let baseName = sanitizedMountName(from: url.lastPathComponent)
        let name = uniqueMountName(baseName, existing: mounts.map(\.name))
        let mount = LocalAlpineExternalMount(
            id: UUID().uuidString,
            name: name,
            displayName: url.lastPathComponent.isEmpty ? name : url.lastPathComponent,
            bookmarkData: bookmarkData,
            allowWrites: allowWrites,
            addedAt: Date()
        )
        mounts.append(mount)
        saveMounts(mounts)
        ensureMountPlaceholders(for: mounts)
        return mount
    }

    static func removeMount(id: String) {
        var mounts = loadMounts()
        mounts.removeAll { $0.id == id }
        saveMounts(mounts)
        ensureMountPlaceholders(for: mounts)
    }

    static func setAllowWrites(id: String, allowWrites: Bool) {
        var mounts = loadMounts()
        guard let index = mounts.firstIndex(where: { $0.id == id }) else { return }
        mounts[index].allowWrites = allowWrites
        saveMounts(mounts)
    }

    static func runtimeMountsConfiguration() -> String {
        loadMounts().compactMap { mount in
            guard let url = resolvedURL(for: mount, startAccessing: true) else { return nil }
            let path = url.standardizedFileURL.path
            guard !mount.name.isEmpty,
                  !mount.name.contains("\t"),
                  !mount.name.contains("\n"),
                  !path.contains("\t"),
                  !path.contains("\n") else {
                return nil
            }
            return "\(mount.name)\t\(mount.allowWrites ? "rw" : "ro")\t\(path)"
        }
        .joined(separator: "\n")
    }

    static func isModelReadOnlyPath(_ rawPath: String) -> Bool {
        let normalized = normalizedSharedPath(rawPath)
        guard normalized == "/mounts" || normalized.hasPrefix("/mounts/") else { return false }
        let remainder = normalized == "/mounts"
            ? ""
            : String(normalized.dropFirst("/mounts/".count))
        guard let mountName = remainder.split(separator: "/", maxSplits: 1).first.map(String.init),
              !mountName.isEmpty,
              let mount = loadMounts().first(where: { $0.name == mountName }) else {
            return true
        }
        return !mount.allowWrites
    }

    static func resolvedWorkspaceURL(for rawPath: String) -> URL? {
        let normalized = normalizedSharedPath(rawPath)
        guard normalized.hasPrefix("/mounts/") else { return nil }
        let remainder = String(normalized.dropFirst("/mounts/".count))
        let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let mountName = parts.first.map(String.init),
              let mount = loadMounts().first(where: { $0.name == mountName }),
              let rootURL = resolvedURL(for: mount, startAccessing: true)?.standardizedFileURL else {
            return nil
        }
        let relativePath = parts.count > 1 ? String(parts[1]) : ""
        let candidate = relativePath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootURL.path + "/") else {
            return nil
        }
        return candidate
    }

    static func ensureMountPlaceholdersForStoredMounts() {
        ensureMountPlaceholders(for: loadMounts())
    }

    private static func saveMounts(_ mounts: [LocalAlpineExternalMount]) {
        guard let data = try? JSONEncoder().encode(Array(mounts.prefix(maximumMounts))) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func resolvedURL(for mount: LocalAlpineExternalMount, startAccessing: Bool) -> URL? {
        var isStale = false
        #if os(macOS)
        let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let resolutionOptions: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(
            resolvingBookmarkData: mount.bookmarkData,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if startAccessing {
            _ = url.startAccessingSecurityScopedResource()
        }
        return url
    }

    private static func normalizedSharedPath(_ rawPath: String) -> String {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/mnt/iexa/") {
            normalized = "/" + String(normalized.dropFirst("/mnt/iexa/".count))
        } else if normalized == "/mnt/iexa" {
            normalized = "/"
        }
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
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

    private static func sanitizedMountName(from rawName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var result = ""
        var lastWasDash = false
        for scalar in rawName.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return trimmed.isEmpty ? "mount" : String(trimmed.prefix(48))
    }

    private static func uniqueMountName(_ baseName: String, existing: [String]) -> String {
        let existingNames = Set(existing)
        if !existingNames.contains(baseName) {
            return baseName
        }
        for index in 2...maximumMounts {
            let candidate = "\(baseName)-\(index)"
            if !existingNames.contains(candidate) {
                return candidate
            }
        }
        return "\(baseName)-\(UUID().uuidString.prefix(6))"
    }

    private static func ensureMountPlaceholders(for mounts: [LocalAlpineExternalMount]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let mountsURL = documents
            .appendingPathComponent(workspaceFolderName, isDirectory: true)
            .appendingPathComponent(sharedFolderName, isDirectory: true)
            .appendingPathComponent("mounts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mountsURL, withIntermediateDirectories: true)
            for mount in mounts {
                try FileManager.default.createDirectory(
                    at: mountsURL.appendingPathComponent(mount.name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        } catch {
            // The runtime can still apply mounts even if the browser placeholder fails.
        }
    }
}

nonisolated struct LocalAlpineStatus: Sendable {
    let isRuntimeLinked: Bool
    let isRootFSBundled: Bool
    let rootArchiveName: String
    let workspacePath: String
}

nonisolated enum LocalAlpineMirrorKind: String, Codable, Sendable {
    case apk
    case pip
    case npm
}

nonisolated struct LocalAlpineMirrorOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let region: String
    let url: String
    let isOfficial: Bool
}

nonisolated struct LocalAlpineMirrorSettings: Codable, Equatable, Sendable {
    var apkMirrorsEnabled: Bool = true
    var pipMirrorsEnabled: Bool = true
    var npmMirrorsEnabled: Bool = true
    var selectedAPKMirrorID: String = "alibaba"
    var selectedPipMirrorID: String = "alibaba"
    var selectedNpmMirrorID: String = "npmmirror"
}

nonisolated struct LocalAlpineRootFSManagementStatus: Sendable {
    let isRuntimeLinked: Bool
    let isRootFSBundled: Bool
    let isRuntimeRootFSInstalled: Bool
    let rootFSSizeBytes: Int64
    let rootFSDisplayPath: String
    let apkMirrorName: String
    let pipMirrorName: String
    let apkMirrorURL: String
    let pipMirrorURL: String
    let npmMirrorName: String
    let npmMirrorURL: String
}

nonisolated enum LocalAlpineMirrorStore {
    private static let storageKey = "localAlpine.mirrorSettings.v1"

    static let apkMirrors: [LocalAlpineMirrorOption] = [
        LocalAlpineMirrorOption(id: "official", name: "Official CDN", region: "Global", url: "https://dl-cdn.alpinelinux.org/alpine/", isOfficial: true),
        LocalAlpineMirrorOption(id: "tsinghua", name: "Tsinghua TUNA", region: "China", url: "https://mirrors.tuna.tsinghua.edu.cn/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "alibaba", name: "Alibaba", region: "China", url: "https://mirrors.aliyun.com/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "ustc", name: "USTC", region: "China", url: "https://mirrors.ustc.edu.cn/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "huawei", name: "Huawei", region: "China", url: "https://repo.huaweicloud.com/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "tencent", name: "Tencent", region: "China", url: "https://mirrors.cloud.tencent.com/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "leaseweb-uk", name: "LEASEWEB UK", region: "Europe", url: "https://mirror.leaseweb.com/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "rwth", name: "RWTH Germany", region: "Europe", url: "https://ftp.halifax.rwth-aachen.de/alpine/", isOfficial: false),
        LocalAlpineMirrorOption(id: "jaist", name: "JAIST Japan", region: "Asia", url: "https://ftp.jaist.ac.jp/pub/Linux/alpine/", isOfficial: false)
    ]

    static let pipMirrors: [LocalAlpineMirrorOption] = [
        LocalAlpineMirrorOption(id: "official", name: "Official PyPI", region: "Global", url: "https://pypi.org/simple/", isOfficial: true),
        LocalAlpineMirrorOption(id: "tsinghua", name: "Tsinghua TUNA", region: "China", url: "https://pypi.tuna.tsinghua.edu.cn/simple/", isOfficial: false),
        LocalAlpineMirrorOption(id: "alibaba", name: "Alibaba", region: "China", url: "https://mirrors.aliyun.com/pypi/simple/", isOfficial: false),
        LocalAlpineMirrorOption(id: "ustc", name: "USTC", region: "China", url: "https://mirrors.ustc.edu.cn/pypi/web/simple/", isOfficial: false),
        LocalAlpineMirrorOption(id: "huawei", name: "Huawei", region: "China", url: "https://repo.huaweicloud.com/repository/pypi/simple/", isOfficial: false),
        LocalAlpineMirrorOption(id: "tencent", name: "Tencent", region: "China", url: "https://mirrors.cloud.tencent.com/pypi/simple/", isOfficial: false)
    ]

    static let npmMirrors: [LocalAlpineMirrorOption] = [
        LocalAlpineMirrorOption(id: "official", name: "Official npm", region: "Global", url: "https://registry.npmjs.org/", isOfficial: true),
        LocalAlpineMirrorOption(id: "npmmirror", name: "npmmirror", region: "China", url: "https://registry.npmmirror.com/", isOfficial: false),
        LocalAlpineMirrorOption(id: "tencent", name: "Tencent", region: "China", url: "https://mirrors.cloud.tencent.com/npm/", isOfficial: false),
        LocalAlpineMirrorOption(id: "huawei", name: "Huawei", region: "China", url: "https://repo.huaweicloud.com/repository/npm/", isOfficial: false)
    ]

    static func load() -> LocalAlpineMirrorSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(LocalAlpineMirrorSettings.self, from: data) else {
            return LocalAlpineMirrorSettings()
        }
        return settings
    }

    static func save(_ settings: LocalAlpineMirrorSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func selectedAPKMirror(settings: LocalAlpineMirrorSettings = load()) -> LocalAlpineMirrorOption {
        guard settings.apkMirrorsEnabled else { return apkMirrors[0] }
        return apkMirrors.first(where: { $0.id == settings.selectedAPKMirrorID }) ?? apkMirrors[0]
    }

    static func selectedPipMirror(settings: LocalAlpineMirrorSettings = load()) -> LocalAlpineMirrorOption {
        guard settings.pipMirrorsEnabled else { return pipMirrors[0] }
        return pipMirrors.first(where: { $0.id == settings.selectedPipMirrorID }) ?? pipMirrors[0]
    }

    static func selectedNpmMirror(settings: LocalAlpineMirrorSettings = load()) -> LocalAlpineMirrorOption {
        guard settings.npmMirrorsEnabled else { return npmMirrors[0] }
        return npmMirrors.first(where: { $0.id == settings.selectedNpmMirrorID }) ?? npmMirrors[0]
    }
}

nonisolated struct LocalAlpineCommandResult: Sendable {
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

nonisolated enum LocalAlpineCommandExecutionMode: Sendable {
    case oneShot
    case persistentAgent(sessionKey: String, timeoutSeconds: TimeInterval)
}

nonisolated struct LocalAlpineFileSample: Sendable {
    let data: Data
    let fullSize: Int64?

    var isTruncated: Bool {
        guard let fullSize else { return false }
        return Int64(data.count) < fullSize
    }
}

nonisolated struct LocalAlpineInteractiveRequest: Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable {
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

nonisolated struct LocalAlpineRootFSResetResult: Sendable {
    let resetImmediately: Bool
    let message: String
}

nonisolated struct LocalAlpineSessionStartResult: Sendable {
    let sessionID: Int?
    let message: String?
}

nonisolated struct LocalAlpineOpenRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let target: String

    var webURL: URL? {
        guard let normalizedTarget = Self.normalizedWebTarget(target),
              let url = URL(string: normalizedTarget),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else {
            return nil
        }
        if (url.host ?? "").caseInsensitiveCompare("iexa.preview") == .orderedSame {
            return nil
        }
        return url
    }

    private static func normalizedWebTarget(_ rawTarget: String) -> String? {
        var candidate = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        if let embeddedURL = firstHTTPURL(in: candidate) {
            candidate = embeddedURL
        }
        candidate = stripTrailingPreviewPunctuation(candidate)
        if isBareLoopbackTarget(candidate) {
            candidate = "http://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else {
            return nil
        }
        if components.host?.lowercased() == "0.0.0.0" {
            components.host = "127.0.0.1"
        }
        return components.string ?? candidate
    }

    private static func firstHTTPURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s"'`<>()\[\]{}]+"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private static func stripTrailingPreviewPunctuation(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingCharacters = CharacterSet(charactersIn: "\"'`*_~.,;:!?)[]{}<>，。！？；：、）】》」』")
        while let scalar = candidate.unicodeScalars.last,
              trailingCharacters.contains(scalar) {
            candidate.removeLast()
        }
        return candidate
    }

    private static func isBareLoopbackTarget(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("localhost:")
            || lowercased.hasPrefix("127.0.0.1:")
            || lowercased.hasPrefix("0.0.0.0:")
            || lowercased.hasPrefix("[::1]:")
    }
}

nonisolated enum LocalAlpineOpenMarkerParser {
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
        BackgroundKeepAliveService.shared.begin(reason: "local-alpine")
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
        Task {
            let sessionInterrupted = await LocalAlpineTerminalService.shared.interruptPersistentAgentSessions()
            let sessionInterruptedText = sessionInterrupted ? "true" : "false"
            Logger(subsystem: "com.openui", category: "LocalAlpine")
                .warning("Local Alpine persistent sessions expired; interrupt sent: \(sessionInterruptedText, privacy: .public)")
        }
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
        BackgroundKeepAliveService.shared.finish(reason: "local-alpine")
    }
}

actor LocalAlpineTerminalService {
    static let shared = LocalAlpineTerminalService()

    private let logger = Logger(subsystem: "com.openui", category: "LocalAlpine")
    private let fileManager = FileManager.default
    private let rootArchiveName = "iexa-alpine-rootfs.fakefs"
    private let bundledRootFSVersion = "3.21.3-aarch64.1"
    private let rootVersionFileName = ".iexa-rootfs-version"
    private let rootResetMarkerFileName = ".iexa-rootfs-reset-pending"
    private let requiredRootFSFakeFSPaths = [
        "/bin/busybox",
        "/bin/sh",
        "/sbin/apk",
        "/etc/alpine-release",
        "/etc/os-release",
        "/etc/apk/repositories",
        "/lib/apk/db/installed",
        "/usr/sbin/fping",
        "/dev"
    ]
    private let requiredRootFSDataPaths = [
        "bin/busybox",
        "bin/sh",
        "sbin/apk",
        "etc/alpine-release",
        "etc/os-release",
        "etc/apk/repositories",
        "lib/apk/db/installed",
        "usr/sbin/fping",
        "dev"
    ]
    private let workspaceFolderName = "Iexa Alpine"
    private let sharedFolderName = "shared"
    private let maximumInlineRuntimeCommandBytes = 3_072
    private var nativeRuntimeStarted = false
    private var prewarmTask: Task<Void, Never>?
    private var lastPrewarmAttemptAt: Date?
    private var persistentAgentSessions: [String: PersistentAgentSession] = [:]
    private var persistentAgentBusyKeys = Set<String>()

    private struct PersistentAgentSession {
        let sessionID: Int
        var lastUsedAt: Date
    }

    static let environmentDiagnosticCommand = """
    printf '== Local Alpine ==\\n'
    printf 'device hardware: iOS arm64/aarch64 outside the sandbox\\n'
    printf 'runtime:         iSH ARM64/aarch64 usermode emulator\\n'
    printf 'apk arch:        '
    apk --print-arch 2>/dev/null || printf 'unknown\\n'
    printf 'uname machine:   '
    uname -m 2>/dev/null || printf 'unknown\\n'
    printf 'rootfs:          '
    cat /etc/alpine-release 2>/dev/null || printf 'unknown\\n'
    printf 'kernel:          '
    uname -a 2>/dev/null || true
    printf 'user:            '
    id 2>/dev/null || true
    printf 'pwd:             '
    pwd
    printf '\\nNote: apk packages in this iSH ARM64 runtime are aarch64 Linux packages.\\n'
    printf '\\n== PATH ==\\n%s\\n' "$PATH"
    printf '\\n== DNS ==\\n'
    cat /etc/resolv.conf 2>/dev/null || true
    printf '\\n== workspace /mnt/iexa ==\\n'
    ls -la /mnt/iexa 2>/dev/null || true
    printf '\\n== core tools ==\\n'
    for x in sh ash busybox apk wget curl ping fping nc python3 pip3 node npm gcc g++ make git tar unzip zip sqlite3; do
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

    func rootFSManagementStatus() throws -> LocalAlpineRootFSManagementStatus {
        let workspaceURL = try ensureWorkspaceDirectory()
        let runtimeRootFSURL = workspaceURL.appendingPathComponent("rootfs.fakefs", isDirectory: true)
        let rootFSInstalled = isRuntimeRootFSUsable(at: runtimeRootFSURL)
        let settings = LocalAlpineMirrorStore.load()
        let apkMirror = LocalAlpineMirrorStore.selectedAPKMirror(settings: settings)
        let pipMirror = LocalAlpineMirrorStore.selectedPipMirror(settings: settings)
        let npmMirror = LocalAlpineMirrorStore.selectedNpmMirror(settings: settings)
        return LocalAlpineRootFSManagementStatus(
            isRuntimeLinked: LocalAlpineNativeRuntime.shared.isLinked,
            isRootFSBundled: bundledRootFSURL() != nil,
            isRuntimeRootFSInstalled: rootFSInstalled,
            rootFSSizeBytes: rootFSInstalled ? directorySize(at: runtimeRootFSURL) : 0,
            rootFSDisplayPath: "Documents/\(workspaceFolderName)/rootfs.fakefs",
            apkMirrorName: apkMirror.name,
            pipMirrorName: pipMirror.name,
            apkMirrorURL: apkMirror.url,
            pipMirrorURL: pipMirror.url,
            npmMirrorName: npmMirror.name,
            npmMirrorURL: npmMirror.url
        )
    }

    func applyMirrorSettings(_ settings: LocalAlpineMirrorSettings) async throws {
        LocalAlpineMirrorStore.save(settings)
        guard let rootArchiveURL = bundledRootFSURL() else {
            throw LocalAlpineError.commandFailed("Local Alpine rootfs is missing from the app bundle: \(rootArchiveName)")
        }
        let workspaceURL = try ensureWorkspaceDirectory()
        let runtimeRootFSURL = try ensureRuntimeRootFSURL(from: rootArchiveURL, workspaceURL: workspaceURL)
        try ensureMirrorConfiguration(in: runtimeRootFSURL, settings: settings)
    }

    func testMirror(_ mirror: LocalAlpineMirrorOption, kind: LocalAlpineMirrorKind) async -> TimeInterval? {
        let targetURLString: String
        switch kind {
        case .apk:
            targetURLString = Self.normalizedMirrorBaseURL(mirror.url)
                + "\(Self.alpineRepositoryBranch(from: bundledRootFSVersion))/main/APKINDEX.tar.gz"
        case .pip:
            targetURLString = mirror.url
        case .npm:
            targetURLString = mirror.url
        }
        guard let url = URL(string: targetURLString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let startedAt = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else {
                return nil
            }
            return Date().timeIntervalSince(startedAt)
        } catch {
            return nil
        }
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
            try ensureMirrorConfiguration(in: runtimeRootFSURL)
        } catch {
            return LocalAlpineSessionStartResult(
                sessionID: nil,
                message: "Local Alpine rootfs could not be prepared for writable local execution: \(error.localizedDescription)"
            )
        }

        let runtimeCWD = cwdIsRuntimePath ? normalizedAbsoluteRuntimePath(cwd) : normalizedRuntimePath(cwd)
        let mountsConfiguration = LocalAlpineMountStore.runtimeMountsConfiguration()
        let sessionID = await LocalAlpineNativeRuntime.shared.startSession(
            LocalAlpineNativeCommand(
                command: "",
                cwd: runtimeCWD,
                rootArchiveURL: runtimeRootFSURL,
                workspaceURL: workspaceURL,
                mountsConfiguration: mountsConfiguration
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
        if let dataRoot = try? runtimeRootFSDataDirectory() {
            let directory = try hostRootFSURL(for: rootPath, dataRoot: dataRoot, allowRoot: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw LocalAlpineError.commandFailed("Not a directory: \(rootPath)")
            }
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: options
            )
            return try urls.map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                let name = url.lastPathComponent
                let itemPath = rootPath == "/" ? "/\(name)" : "\(rootPath)/\(name)"
                let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
                return TerminalFileItem(
                    name: name,
                    path: itemPath,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : values.fileSize.map { Int64($0) },
                    modified: values.contentModificationDate,
                    permissions: nil
                )
            }
        }

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
        if let dataRoot = try? runtimeRootFSDataDirectory() {
            let url = try hostRootFSURL(for: rootPath, dataRoot: dataRoot, allowRoot: false)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else {
                throw LocalAlpineError.commandFailed("Not a regular file: \(rootPath)")
            }
            return try Data(contentsOf: url)
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
        if let dataRoot = try? runtimeRootFSDataDirectory() {
            let url = try hostRootFSURL(for: rootPath, dataRoot: dataRoot, allowRoot: false)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values.isDirectory != true else {
                throw LocalAlpineError.commandFailed("Not a regular file: \(rootPath)")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: max(1, maxBytes)) ?? Data()
            return LocalAlpineFileSample(
                data: data,
                fullSize: values.fileSize.map(Int64.init)
            )
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
        case "", "workspace", "mnt", "iexa":
            return normalizedRuntimePath(path)
        case "shared", "skills", "memory", "mounts", "attachments":
            let combined = path == "/" ? "/\(host)" : "/\(host)\(path)"
            return normalizedRuntimePath(combined)
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
            for host in ["shared", "skills", "memory", "mounts", "attachments"] where decodedPath.hasPrefix("/\(host)/") {
                return "/mnt/iexa" + decodedPath
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
        var normalized = rawTarget
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasPrefix("../"),
              !normalized.contains("/../"),
              !normalized.contains("://"),
              !normalized.contains("\t"),
              normalized.rangeOfCharacter(from: .newlines) == nil,
              !(normalized as NSString).pathExtension.isEmpty else {
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
        if let dataRoot = try? runtimeRootFSDataDirectory() {
            let url = try hostRootFSURL(for: rootPath, dataRoot: dataRoot, allowRoot: false)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
            return
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
        cwdIsRuntimePath: Bool = false,
        executionMode: LocalAlpineCommandExecutionMode = .oneShot,
        onOutput: (@MainActor @Sendable (String) -> Void)? = nil
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

        if case let .persistentAgent(sessionKey, timeoutSeconds) = executionMode {
            return await executePersistentAgentCommand(
                command: trimmed,
                cwd: cwd,
                stdinInput: stdinInput,
                cwdIsRuntimePath: cwdIsRuntimePath,
                sessionKey: sessionKey,
                timeoutSeconds: timeoutSeconds,
                onOutput: onOutput
            )
        }

        if stdinInput == nil, let onOutput = onOutput {
            return await executeStreaming(
                command: trimmed,
                cwd: cwd,
                cwdIsRuntimePath: cwdIsRuntimePath,
                onOutput: onOutput
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
            try ensureMirrorConfiguration(in: runtimeRootFSURL)
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
        let mountsConfiguration = LocalAlpineMountStore.runtimeMountsConfiguration()
        await LocalAlpineBackgroundExecution.begin(reason: "command")
        let result = await LocalAlpineNativeRuntime.shared.execute(
            LocalAlpineNativeCommand(
                command: materialized.command,
                cwd: runtimeCWD,
                rootArchiveURL: runtimeRootFSURL,
                workspaceURL: workspaceURL,
                mountsConfiguration: mountsConfiguration
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

    func interruptPersistentAgentSessions(sessionKey: String? = nil) -> Bool {
        let keys: [String]
        if let sessionKey {
            keys = persistentAgentSessions.keys.filter { $0 == sessionKey }
        } else {
            keys = Array(persistentAgentSessions.keys)
        }

        var interrupted = false
        for key in keys {
            guard let session = persistentAgentSessions.removeValue(forKey: key) else { continue }
            interrupted = LocalAlpineNativeRuntime.shared.interruptSession(sessionID: session.sessionID) || interrupted
            interrupted = LocalAlpineNativeRuntime.shared.closeSession(sessionID: session.sessionID) || interrupted
            persistentAgentBusyKeys.remove(key)
        }
        return interrupted
    }

    private func executePersistentAgentCommand(
        command: String,
        cwd: String,
        stdinInput: String?,
        cwdIsRuntimePath: Bool,
        sessionKey: String,
        timeoutSeconds: TimeInterval,
        onOutput: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> LocalAlpineCommandResult {
        let normalizedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty else {
            return await execute(command: command, cwd: cwd, stdinInput: stdinInput, cwdIsRuntimePath: cwdIsRuntimePath, onOutput: onOutput)
        }

        guard await waitForPersistentAgentSlot(normalizedSessionKey) else {
            return LocalAlpineCommandResult(
                command: command,
                output: "Local Alpine persistent shell was cancelled before this command started.",
                exitCode: 130,
                interactiveRequest: nil
            )
        }
        defer { releasePersistentAgentSlot(normalizedSessionKey) }

        let runtimeCWD = cwdIsRuntimePath
            ? normalizedAbsoluteRuntimePath(cwd)
            : normalizedRuntimePath(cwd)
        let compatibleCommand = compatibilityCommand(for: command)
        let bootstrappedCommand = bootstrappedShellCommand(for: compatibleCommand)
        let runtimeCommand = stdinInput.map {
            wrappedCommandForInteractiveInput(command: bootstrappedCommand, stdinInput: $0)
        } ?? bootstrappedCommand
        let materialized = await materializedRuntimeCommandIfNeeded(runtimeCommand)

        await LocalAlpineBackgroundExecution.begin(reason: "agent-shell")
        let result = await runPersistentAgentMaterializedCommand(
            originalCommand: command,
            materializedCommand: materialized.command,
            runtimeCWD: runtimeCWD,
            sessionKey: normalizedSessionKey,
            timeoutSeconds: effectivePersistentAgentTimeout(for: command, defaultTimeout: timeoutSeconds),
            onOutput: onOutput
        )
        if let cleanupPath = materialized.cleanupPath {
            try? await deleteItem(path: cleanupPath)
        }
        await LocalAlpineBackgroundExecution.finish()
        return result
    }

    private func waitForPersistentAgentSlot(_ sessionKey: String) async -> Bool {
        while persistentAgentBusyKeys.contains(sessionKey) {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        persistentAgentBusyKeys.insert(sessionKey)
        return true
    }

    private func releasePersistentAgentSlot(_ sessionKey: String) {
        persistentAgentBusyKeys.remove(sessionKey)
    }

    private func effectivePersistentAgentTimeout(for command: String, defaultTimeout: TimeInterval) -> TimeInterval {
        let lowered = command.lowercased()
        if lowered.range(of: #"(^|[;&|()\s])(?:busybox\s+)?ping(\s|$)"#, options: .regularExpression) != nil
            || lowered.contains("/ping ") {
            return min(defaultTimeout, 20)
        }
        if lowered.range(of: #"(^|[;&|()\s])(?:dig|host|nslookup|drill)(\s|$)"#, options: .regularExpression) != nil
            || lowered.contains("/dig ")
            || lowered.contains("/host ")
            || lowered.contains("/nslookup ")
            || lowered.contains("/drill ") {
            return min(defaultTimeout, 120)
        }
        return defaultTimeout
    }

    private func effectiveStreamingTimeout(for command: String) -> TimeInterval? {
        let lowered = command.lowercased()
        if lowered.range(of: #"(^|[;&|()\s])(?:dig|host|nslookup|drill)(\s|$)"#, options: .regularExpression) != nil
            || lowered.contains("/dig ")
            || lowered.contains("/host ")
            || lowered.contains("/nslookup ")
            || lowered.contains("/drill ") {
            return 120
        }
        return nil
    }

    private func persistentAgentSessionID(sessionKey: String, runtimeCWD: String) async -> (sessionID: Int?, message: String?) {
        if var existing = persistentAgentSessions[sessionKey] {
            if LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: existing.sessionID, input: "") {
                existing.lastUsedAt = Date()
                persistentAgentSessions[sessionKey] = existing
                return (existing.sessionID, nil)
            }

            _ = LocalAlpineNativeRuntime.shared.closeSession(sessionID: existing.sessionID)
            persistentAgentSessions.removeValue(forKey: sessionKey)
        }

        let startResult = await startInteractiveSession(cwd: runtimeCWD, cwdIsRuntimePath: true)
        guard let sessionID = startResult.sessionID else {
            return (nil, startResult.message ?? "Local Alpine persistent shell could not be started.")
        }

        await configurePersistentAgentShell(sessionID: sessionID)
        persistentAgentSessions[sessionKey] = PersistentAgentSession(sessionID: sessionID, lastUsedAt: Date())
        return (sessionID, nil)
    }

    private func configurePersistentAgentShell(sessionID: Int) async {
        _ = LocalAlpineNativeRuntime.shared.resizeSession(sessionID: sessionID, columns: 120, rows: 40)
        try? await Task.sleep(nanoseconds: 80_000_000)
        _ = LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)
        _ = LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: "stty -echo 2>/dev/null || true\nexport PS1=''\n")
        try? await Task.sleep(nanoseconds: 80_000_000)
        _ = LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)
    }

    private func runPersistentAgentMaterializedCommand(
        originalCommand: String,
        materializedCommand: String,
        runtimeCWD: String,
        sessionKey: String,
        timeoutSeconds: TimeInterval,
        onOutput: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> LocalAlpineCommandResult {
        let session = await persistentAgentSessionID(sessionKey: sessionKey, runtimeCWD: runtimeCWD)
        guard let sessionID = session.sessionID else {
            return LocalAlpineCommandResult(
                command: originalCommand,
                output: session.message ?? "Local Alpine persistent shell could not be started.",
                exitCode: 126,
                interactiveRequest: nil
            )
        }

        let marker = "__IEXA_AGENT_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let markerPrefix = "\(marker):"
        let envelope = persistentAgentCommandEnvelope(
            materializedCommand: materializedCommand,
            runtimeCWD: runtimeCWD,
            markerPrefix: markerPrefix
        )

        guard LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: envelope + "\n") else {
            persistentAgentSessions.removeValue(forKey: sessionKey)
            return LocalAlpineCommandResult(
                command: originalCommand,
                output: "Local Alpine persistent shell is not running.",
                exitCode: 130,
                interactiveRequest: nil
            )
        }

        var rawOutput = ""
        var lastVisibleOutput = ""
        var openTargets = Set<String>()
        var openRequests: [LocalAlpineOpenRequest] = []
        let deadline = Date().addingTimeInterval(max(1, timeoutSeconds))

        func commandResult(rawOutput: String, exitCode: Int?) -> LocalAlpineCommandResult {
            let parsed = LocalAlpineOpenMarkerParser.extract(from: rawOutput)
            for request in parsed.requests where openTargets.insert(request.target).inserted {
                openRequests.append(request)
            }
            return LocalAlpineCommandResult(
                command: originalCommand,
                output: trimTrailingNewlines(parsed.cleaned.replacingOccurrences(of: "\u{0007}", with: "")),
                exitCode: exitCode,
                interactiveRequest: nil,
                openRequests: openRequests
            )
        }

        while Date() < deadline {
            if Task.isCancelled {
                _ = LocalAlpineNativeRuntime.shared.interruptSession(sessionID: sessionID)
                _ = LocalAlpineNativeRuntime.shared.closeSession(sessionID: sessionID)
                persistentAgentSessions.removeValue(forKey: sessionKey)
                let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 130)
            }

            let chunk = LocalAlpineNativeRuntime.shared.readSessionOutput(sessionID: sessionID)
            if !chunk.isEmpty {
                rawOutput += chunk
                let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                let visibleOutput = trimTrailingNewlines(
                    LocalAlpineOpenMarkerParser.extract(from: parsed.visibleOutput)
                        .cleaned
                        .replacingOccurrences(of: "\u{0007}", with: "")
                )
                if visibleOutput != lastVisibleOutput {
                    lastVisibleOutput = visibleOutput
                    await onOutput?(visibleOutput)
                }
                if parsed.finished {
                    if var stored = persistentAgentSessions[sessionKey] {
                        stored.lastUsedAt = Date()
                        persistentAgentSessions[sessionKey] = stored
                    }
                    return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 0)
                }
            } else if !LocalAlpineNativeRuntime.shared.writeSessionInput(sessionID: sessionID, input: "") {
                persistentAgentSessions.removeValue(forKey: sessionKey)
                let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                return commandResult(rawOutput: parsed.rawOutput, exitCode: parsed.exitCode ?? 130)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        _ = LocalAlpineNativeRuntime.shared.interruptSession(sessionID: sessionID)
        _ = LocalAlpineNativeRuntime.shared.closeSession(sessionID: sessionID)
        persistentAgentSessions.removeValue(forKey: sessionKey)
        let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
        let timedOutOutput = trimTrailingNewlines(parsed.rawOutput)
        let suffix = "[Command timed out after \(Int(max(1, timeoutSeconds)))s]"
        return commandResult(
            rawOutput: timedOutOutput.isEmpty ? suffix : "\(timedOutOutput)\n\(suffix)",
            exitCode: 124
        )
    }

    private func persistentAgentCommandEnvelope(
        materializedCommand: String,
        runtimeCWD: String,
        markerPrefix: String
    ) -> String {
        """
        __iexa_agent_status=0
        stty -echo 2>/dev/null || true
        export PS1=''
        if cd \(shellSingleQuoted(runtimeCWD)); then
        /bin/sh -lc \(shellSingleQuoted(materializedCommand))
        __iexa_agent_status=$?
        else
        __iexa_agent_status=$?
        fi
        printf '\\n\(markerPrefix)%s\\n' "$__iexa_agent_status"
        """
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
            try ensureMirrorConfiguration(in: runtimeRootFSURL)
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
            timeoutSeconds: effectiveStreamingTimeout(for: trimmed),
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
        for directoryName in ["shared", "skills", "memory", "mounts"] {
            try fileManager.createDirectory(
                at: shared.appendingPathComponent(directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        LocalAlpineMountStore.ensureMountPlaceholdersForStoredMounts()
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
        let hasExistingRootFS = fileManager.fileExists(atPath: dataURL.path)
            && fileManager.fileExists(atPath: metadataURL.path)
        let existingRootFSIsUsable = hasExistingRootFS && isRuntimeRootFSUsable(at: writableURL)

        if existingRootFSIsUsable,
           storedRootFSVersion(at: versionURL) == bundledRootFSVersion,
           !hasPendingReset {
            return writableURL.standardizedFileURL
        }

        if hasPendingReset, nativeRuntimeStarted,
           hasExistingRootFS {
            return writableURL.standardizedFileURL
        }

        if nativeRuntimeStarted,
           hasExistingRootFS {
            try? "rootfs upgrade pending\n".write(to: resetMarkerURL, atomically: true, encoding: .utf8)
            return writableURL.standardizedFileURL
        }

        let temporaryURL = workspaceURL.appendingPathComponent("rootfs.fakefs.tmp-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: temporaryURL)
        try fileManager.copyItem(at: bundledURL, to: temporaryURL)
        guard isRuntimeRootFSUsable(at: temporaryURL) else {
            try? fileManager.removeItem(at: temporaryURL)
            throw LocalAlpineError.commandFailed("Local Alpine bundled fakefs is incomplete; please rebuild the IPA with a valid iexa-alpine-rootfs.fakefs resource.")
        }
        if fileManager.fileExists(atPath: writableURL.path) {
            try fileManager.removeItem(at: writableURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: writableURL)
        try? bundledRootFSVersion.write(to: versionURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: resetMarkerURL)
        return writableURL.standardizedFileURL
    }

    private func isRuntimeRootFSUsable(at url: URL) -> Bool {
        guard url.pathExtension == "fakefs" else { return true }
        let dataURL = url.appendingPathComponent("data", isDirectory: true)
        guard fileManager.fileExists(atPath: dataURL.path),
              fileManager.fileExists(atPath: url.appendingPathComponent("meta.db").path) else {
            return false
        }
        for path in requiredRootFSDataPaths {
            guard fileManager.fileExists(atPath: dataURL.appendingPathComponent(path).path) else {
                return false
            }
        }
        return LocalAlpineNativeRuntime.shared.fakeFSContainsPaths(
            at: url,
            requiredPaths: requiredRootFSFakeFSPaths
        )
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

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func ensureResolverConfiguration(in runtimeRootFSURL: URL) throws {
        guard runtimeRootFSURL.pathExtension == "fakefs" else { return }

        let dataURL = runtimeRootFSURL.appendingPathComponent("data", isDirectory: true)
        let etcURL = dataURL.appendingPathComponent("etc", isDirectory: true)
        let resolvURL = etcURL.appendingPathComponent("resolv.conf")
        let resolver = """
        # managed by Iexa Local Alpine
        nameserver 223.5.5.5
        nameserver 119.29.29.29
        nameserver 1.1.1.1
        options timeout:2 attempts:3

        """

        if let existing = try? String(contentsOf: resolvURL, encoding: .utf8),
           existing.contains("# managed by Iexa Local Alpine"),
           existing.contains("nameserver 223.5.5.5"),
           existing.contains("nameserver 119.29.29.29") {
            return
        }

        try fileManager.createDirectory(at: etcURL, withIntermediateDirectories: true)
        try resolver.write(to: resolvURL, atomically: true, encoding: .utf8)
    }

    private func ensureMirrorConfiguration(
        in runtimeRootFSURL: URL,
        settings: LocalAlpineMirrorSettings = LocalAlpineMirrorStore.load()
    ) throws {
        guard runtimeRootFSURL.pathExtension == "fakefs" else { return }

        let dataURL = runtimeRootFSURL.appendingPathComponent("data", isDirectory: true)
        let apkMirror = LocalAlpineMirrorStore.selectedAPKMirror(settings: settings)
        let pipMirror = LocalAlpineMirrorStore.selectedPipMirror(settings: settings)
        let npmMirror = LocalAlpineMirrorStore.selectedNpmMirror(settings: settings)
        let branch = Self.alpineRepositoryBranch(from: bundledRootFSVersion)
        let apkBase = Self.normalizedMirrorBaseURL(apkMirror.url)
        let repositories = """
        \(apkBase)\(branch)/main
        \(apkBase)\(branch)/community

        """

        let apkURL = dataURL
            .appendingPathComponent("etc", isDirectory: true)
            .appendingPathComponent("apk", isDirectory: true)
        try fileManager.createDirectory(at: apkURL, withIntermediateDirectories: true)
        try repositories.write(
            to: apkURL.appendingPathComponent("repositories"),
            atomically: true,
            encoding: .utf8
        )

        let pipConfig = """
        [global]
        index-url = \(pipMirror.url)
        timeout = 15
        retries = 2
        break-system-packages = true

        """
        let rootPipURL = dataURL
            .appendingPathComponent("root", isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("pip", isDirectory: true)
        try fileManager.createDirectory(at: rootPipURL, withIntermediateDirectories: true)
        try pipConfig.write(
            to: rootPipURL.appendingPathComponent("pip.conf"),
            atomically: true,
            encoding: .utf8
        )

        let etcURL = dataURL.appendingPathComponent("etc", isDirectory: true)
        try fileManager.createDirectory(at: etcURL, withIntermediateDirectories: true)
        try pipConfig.write(
            to: etcURL.appendingPathComponent("pip.conf"),
            atomically: true,
            encoding: .utf8
        )

        let npmConfig = """
        registry=\(npmMirror.url)
        audit=false
        fund=false
        progress=false
        update-notifier=false
        fetch-timeout=15000
        fetch-retries=1
        jobs=1
        maxsockets=2

        """
        try npmConfig.write(
            to: etcURL.appendingPathComponent("npmrc"),
            atomically: true,
            encoding: .utf8
        )
        let rootURL = dataURL.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try npmConfig.write(
            to: rootURL.appendingPathComponent(".npmrc"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func normalizedMirrorBaseURL(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("/") ? trimmed : "\(trimmed)/"
    }

    private static func alpineRepositoryBranch(from version: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)"#),
              let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)),
              match.numberOfRanges >= 3,
              let majorRange = Range(match.range(at: 1), in: version),
              let minorRange = Range(match.range(at: 2), in: version) else {
            return "v3.21"
        }
        return "v\(version[majorRange]).\(version[minorRange])"
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

        to_iexa_resource() {
          case "$1" in
            http://*|https://*|about:*|file://*|iexa://*)
              printf '%s\\n' "$1"
              ;;
            /mnt/iexa/*)
              rel="${1#/mnt/iexa/}"
              case "$rel" in
                shared/*|skills/*|memory/*|mounts/*|attachments/*)
                  host="${rel%%/*}"
                  path="${rel#*/}"
                  printf 'iexa://%s/%s\\n' "$host" "$path"
                  ;;
                *)
                  printf 'iexa://workspace/%s\\n' "$rel"
                  ;;
              esac
              ;;
            /mnt/iexa)
              printf 'iexa://workspace/\\n'
              ;;
            /*)
              printf '%s\\n' "$1"
              ;;
            *)
              resolved=$(readlink -f "$1" 2>/dev/null || true)
              if [ -n "$resolved" ]; then
                to_iexa_resource "$resolved"
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
          target=$(to_iexa_resource "$arg")
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
          printf '       iexa-serve stop [port|all]\\n' >&2
          exit 0
        fi

        runtime_dir=/tmp/iexa-serve
        mkdir -p "$runtime_dir"

        if [ "${1:-}" = "stop" ] || [ "${1:-}" = "--stop" ]; then
          stop_target=${2:-all}
          is_managed_http_pid() {
            [ -n "${1:-}" ] || return 1
            if [ -r "/proc/$1/cmdline" ]; then
              tr '\\000' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -Eq 'python3? -m http[.]server|busybox .*httpd|httpd' && return 0
              return 1
            fi
            return 0
          }
          stop_one() {
            stop_port="$1"
            stop_pidfile="$runtime_dir/$stop_port.pid"
            stop_dirfile="$runtime_dir/$stop_port.dir"
            if [ ! -f "$stop_pidfile" ]; then
              printf 'No managed Iexa preview server on port %s.\\n' "$stop_port"
              return 1
            fi
            stop_pid=$(cat "$stop_pidfile" 2>/dev/null || true)
            if [ -n "$stop_pid" ] && kill -0 "$stop_pid" 2>/dev/null; then
              if is_managed_http_pid "$stop_pid"; then
                kill "$stop_pid" 2>/dev/null || true
                printf 'Stopped Iexa preview server on port %s.\\n' "$stop_port"
              else
                printf 'Refused to stop non-preview process from stale pidfile on port %s.\\n' "$stop_port" >&2
                return 1
              fi
            else
              printf 'Removed stale Iexa preview pidfile for port %s.\\n' "$stop_port"
            fi
            rm -f "$stop_pidfile" "$stop_dirfile"
            return 0
          }
          stopped=0
          if [ "$stop_target" = "all" ]; then
            for stop_pidfile in "$runtime_dir"/*.pid; do
              [ -e "$stop_pidfile" ] || continue
              stop_port=${stop_pidfile##*/}
              stop_port=${stop_port%.pid}
              stop_one "$stop_port" && stopped=1
            done
            [ "$stopped" -eq 1 ] || printf 'No managed Iexa preview servers are running.\\n'
            exit 0
          fi
          case "$stop_target" in
            ''|*[!0-9]*)
              printf 'iexa-serve stop: port must be a number or all.\\n' >&2
              exit 1
              ;;
          esac
          stop_one "$stop_target"
          exit $?
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

        print_urls() {
          token=$(date +%s 2>/dev/null || printf '%s' "$$")
          url="http://localhost:$1/?iexa_preview=$token"
          printf 'Preview URL: %s\\n' "$url"
          printf 'Loopback URL: http://127.0.0.1:%s/?iexa_preview=%s\\n' "$1" "$token"
          printf '访问地址: %s\\n' "$url"
          emit_open_marker "$url"
        }

        pid_alive() {
          [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
        }

        socket_port_in_use() {
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
          if command -v nc >/dev/null 2>&1; then
            if command -v timeout >/dev/null 2>&1; then
              timeout 1 nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
            else
              nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
            fi
            return 1
          fi
          return 2
        }

        server_ready() {
          socket_port_in_use "$1"
          socket_status=$?
          [ "$socket_status" -eq 0 ] && return 0
          if command -v python3 >/dev/null 2>&1; then
            python3 - "$1" <<'PY' >/dev/null 2>&1 && return 0
        import socket
        import sys

        sock = socket.socket()
        sock.settimeout(0.5)
        sock.connect(("127.0.0.1", int(sys.argv[1])))
        sock.close()
        PY
          fi
          return "$socket_status"
        }

        existing_server_for_dir() {
          candidate_port="$1"
          candidate_pidfile="$runtime_dir/$candidate_port.pid"
          candidate_dirfile="$runtime_dir/$candidate_port.dir"
          [ -f "$candidate_pidfile" ] || return 1
          candidate_pid=$(cat "$candidate_pidfile" 2>/dev/null || true)
          pid_alive "$candidate_pid" || return 1
          candidate_dir=$(cat "$candidate_dirfile" 2>/dev/null || true)
          if [ "$candidate_dir" = "$dir" ]; then
            printf 'Iexa local preview server already running.\\n'
            printf 'Directory: %s\\n' "$dir"
            printf 'PID: %s\\n' "$candidate_pid"
            print_urls "$candidate_port"
            exit 0
          fi
          socket_port_in_use "$candidate_port"
          socket_status=$?
          if [ "$socket_status" -eq 1 ]; then
            return 1
          fi
          return 1
        }

        port_in_use() {
          pidfile="$runtime_dir/$1.pid"
          if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null || true)
            if pid_alive "$pid"; then
              return 0
            fi
          fi
          socket_port_in_use "$1"
          socket_status=$?
          if [ "$socket_status" -eq 0 ]; then
            return 0
          elif [ "$socket_status" -eq 1 ]; then
            return 1
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
        server_ready "$port" >/dev/null 2>&1 || true

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
        printf '%s is disabled in Iexa Local Alpine because it is unreliable in the embedded iSH runtime.\\n' "$(basename "$0")" >&2
        printf 'For localhost preview checks, use `nc -z 127.0.0.1 <port>` or inspect /proc/net/tcp.\\n' >&2
        exit 127
        """
        try writeExecutableText(lsofShim, to: binURL.appendingPathComponent("lsof"))
        try writeExecutableText(lsofShim, to: binURL.appendingPathComponent("netstat"))

        try writeExecutableText(localPingShimScript, to: binURL.appendingPathComponent("ping"))
        try writeExecutableText(localTopShimScript, to: binURL.appendingPathComponent("top"))

        let profileURL = dataURL.appendingPathComponent("etc/profile.d", isDirectory: true)
        try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)
        let profile = """
        export BROWSER=/usr/local/bin/iexa-open
        export LANG=${LANG:-C.UTF-8}
        export LC_ALL=${LC_ALL:-C.UTF-8}
        export NO_COLOR=${NO_COLOR:-1}
        export PAGER=${PAGER:-less}
        export PYTHONDONTWRITEBYTECODE=${PYTHONDONTWRITEBYTECODE:-1}
        export GOMAXPROCS=${GOMAXPROCS:-2}
        export UV_LINK_MODE=${UV_LINK_MODE:-symlink}

        """
        try profile.write(to: profileURL.appendingPathComponent("iexa-open.sh"), atomically: true, encoding: .utf8)
    }

    private func writeExecutableText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var localPingShimScript: String {
        """
        #!/bin/sh
        busybox_ping=
        for candidate in /bin/busybox /usr/bin/busybox /sbin/busybox /usr/sbin/busybox; do
          if [ -x "$candidate" ]; then
            busybox_ping="$candidate"
            break
          fi
        done

        real_ping=
        if [ -z "$busybox_ping" ]; then
          for candidate in /bin/ping /usr/bin/ping /sbin/ping /usr/sbin/ping; do
            if [ -x "$candidate" ]; then
              real_ping="$candidate"
              break
            fi
          done
        fi

        if [ -z "$busybox_ping" ] && [ -z "$real_ping" ]; then
          printf '/bin/sh: ping: not found\\n' >&2
          exit 127
        fi

        count=4
        wait_seconds=2
        has_limit=0
        previous=
        for arg in "$@"; do
          if [ "$previous" = "-c" ]; then
            case "$arg" in ''|*[!0-9]*) ;; *) count="$arg" ;; esac
            previous=
            continue
          fi
          if [ "$previous" = "-W" ] || [ "$previous" = "-w" ]; then
            case "$arg" in ''|*[!0-9]*) ;; *) wait_seconds="$arg" ;; esac
            previous=
            continue
          fi
          case "$arg" in
            -c)
              has_limit=1
              previous=-c
              ;;
            -c*)
              has_limit=1
              value="${arg#-c}"
              case "$value" in ''|*[!0-9]*) ;; *) count="$value" ;; esac
              ;;
            -w|-W)
              has_limit=1
              previous="$arg"
              ;;
            -w*|-W*)
              has_limit=1
              value="${arg#-w}"
              [ "$value" = "$arg" ] && value="${arg#-W}"
              case "$value" in ''|*[!0-9]*) ;; *) wait_seconds="$value" ;; esac
              ;;
            --help|-h)
              has_limit=1
              ;;
          esac
        done
        [ "$count" -gt 0 ] 2>/dev/null || count=4
        [ "$wait_seconds" -gt 0 ] 2>/dev/null || wait_seconds=2

        target=
        for arg in "$@"; do
          case "$arg" in
            -*) ;;
            *)
              case "$arg" in ''|*[!0-9]*) target="$arg" ;; esac
              ;;
          esac
        done
        [ -n "$target" ] || target="host"
        timeout_ms=$((wait_seconds * 1000))
        [ "$timeout_ms" -gt 0 ] 2>/dev/null || timeout_ms=2000

        run_ping() {
          if [ -n "$busybox_ping" ]; then
            "$busybox_ping" ping "$@"
          else
            "$real_ping" "$@"
          fi
        }

        run_fping_if_available() {
          fping_bin="$(command -v fping 2>/dev/null || true)"
          [ -n "$fping_bin" ] || return 127
          [ "$target" != "host" ] || return 127
          tmp="/tmp/iexa-fping-$$.log"
          : > "$tmp" 2>/dev/null || {
            tmp="/mnt/iexa/shared/.iexa-fping-$$.log"
            : > "$tmp" 2>/dev/null || return 125
          }
          "$fping_bin" -c "$count" -t "$timeout_ms" "$target" >"$tmp" 2>&1
          status=$?
          cat "$tmp" 2>/dev/null
          if grep -Eq -- 'xmt/rcv/%loss = [0-9]+/[1-9][0-9]*/' "$tmp" 2>/dev/null ||
             grep -Eq -- '(^|[[:space:]])64 bytes,' "$tmp" 2>/dev/null; then
            rm -f "$tmp" >/dev/null 2>&1 || true
            return 0
          fi
          rm -f "$tmp" >/dev/null 2>&1 || true
          return "$status"
        }

        print_supervised_stats() {
          awk -v target="$target" -v transmitted="$count" '
            / bytes from / {
              received++
              if (match($0, /time=[0-9.]+/)) {
                value = substr($0, RSTART + 5, RLENGTH - 5) + 0
                if (samples == 0 || value < min) min = value
                if (samples == 0 || value > max) max = value
                sum += value
                samples++
              }
            }
            END {
              if (received > 0) {
                loss = transmitted > 0 ? int(((transmitted - received) * 100) / transmitted) : 0
                printf "\\n--- %s ping statistics ---\\n", target
                printf "%d packets transmitted, %d packets received, %d%% packet loss\\n", transmitted, received, loss
                if (samples > 0) {
                  printf "round-trip min/avg/max = %.3f/%.3f/%.3f ms\\n", min, sum / samples, max
                }
              }
            }
          ' "$1"
        }

        supervised_ping() {
          tmp="/tmp/iexa-ping-$$.log"
          : > "$tmp" 2>/dev/null || {
            tmp="/mnt/iexa/shared/.iexa-ping-$$.log"
            : > "$tmp" 2>/dev/null || exit 125
          }
          if [ -n "$busybox_ping" ]; then
            "$busybox_ping" ping "$@" >"$tmp" 2>&1 &
          else
            "$real_ping" "$@" >"$tmp" 2>&1 &
          fi
          pid=$!
          deadline=$((count * wait_seconds + 4))
          [ "$deadline" -lt 6 ] && deadline=6
          [ "$deadline" -gt 15 ] && deadline=15
          elapsed=0
          while [ "$elapsed" -lt "$deadline" ]; do
            if grep -Eq -- '(^|[[:space:]])[0-9]+ bytes from ' "$tmp" 2>/dev/null; then
              replies="$(grep -E -- '(^|[[:space:]])[0-9]+ bytes from ' "$tmp" 2>/dev/null | wc -l | tr -d ' ')"
              if [ "$replies" -ge "$count" ] 2>/dev/null || grep -q -- ' ping statistics ' "$tmp" 2>/dev/null; then
                break
              fi
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
              break
            fi
            sleep 1 2>/dev/null || break
            elapsed=$((elapsed + 1))
          done
          cat "$tmp" 2>/dev/null
          if ! grep -q -- ' ping statistics ' "$tmp" 2>/dev/null; then
            print_supervised_stats "$tmp"
          fi
          replies="$(grep -E -- '(^|[[:space:]])[0-9]+ bytes from ' "$tmp" 2>/dev/null | wc -l | tr -d ' ')"
          kill "$pid" >/dev/null 2>&1 || true
          rm -f "$tmp" >/dev/null 2>&1 || true
          [ "$replies" -gt 0 ] 2>/dev/null
        }

        if [ "$has_limit" -eq 1 ]; then
          run_fping_if_available && exit 0
          supervised_ping "$@"
        else
          run_fping_if_available && exit 0
          supervised_ping -c 4 -W 2 "$@"
        fi
        """
    }

    private var localTopShimScript: String {
        """
        #!/bin/sh
        delay=2
        iterations=-1
        batch=0

        while [ "$#" -gt 0 ]; do
          case "$1" in
            -d)
              delay=${2:-2}
              shift 2
              ;;
            -n)
              iterations=${2:-1}
              shift 2
              ;;
            -b)
              batch=1
              shift
              ;;
            -h|--help)
              printf 'Usage: top [-b] [-n COUNT] [-d SECONDS]\\n'
              exit 0
              ;;
            *)
              shift
              ;;
          esac
        done

        case "$delay" in ''|*[!0-9]*) delay=2 ;; esac
        [ "$delay" -gt 0 ] 2>/dev/null || delay=2
        iterations_check="$iterations"
        case "$iterations_check" in -*) iterations_check="${iterations_check#-}" ;; esac
        case "$iterations_check" in ''|*[!0-9]*) iterations=-1 ;; esac

        render_once() {
          uptime_text=$(awk '{printf "%s", int($1)}' /proc/uptime 2>/dev/null || printf '0')
          visible=$(for d in /proc/[0-9]*; do [ -r "$d/stat" ] && printf '.\\n'; done 2>/dev/null | wc -l | tr -d ' ')
          [ -n "$visible" ] || visible=0
          printf 'top - up %ss, visible processes: %s\\n' "$uptime_text" "$visible"
          if command -v ps >/dev/null 2>&1; then
            ps 2>/dev/null | head -40
          elif command -v busybox >/dev/null 2>&1; then
            busybox ps 2>/dev/null | head -40
          else
            printf 'top: ps is not available in this sandbox\\n' >&2
            return 1
          fi
        }

        count=0
        if [ "$batch" -eq 1 ]; then
          [ "$iterations" -lt 0 ] && iterations=1
          while [ "$count" -lt "$iterations" ]; do
            render_once
            count=$((count + 1))
            [ "$count" -ge "$iterations" ] && break
            sleep "$delay"
          done
          exit 0
        fi

        saved_stty=""
        if [ -t 0 ]; then
          saved_stty=$(stty -g 2>/dev/null || true)
          stty -echo -icanon min 0 time 0 2>/dev/null || true
        fi
        cleanup_top() {
          [ -n "$saved_stty" ] && stty "$saved_stty" 2>/dev/null || true
          printf '\\033[?25h'
        }
        trap cleanup_top INT TERM EXIT
        printf '\\033[?25l'

        while [ "$iterations" -lt 0 ] || [ "$count" -lt "$iterations" ]; do
          printf '\\033[H\\033[2J'
          render_once
          count=$((count + 1))
          [ "$iterations" -ge 0 ] && [ "$count" -ge "$iterations" ] && break
          end=$(( $(date +%s 2>/dev/null || printf '0') + delay ))
          while [ "$(date +%s 2>/dev/null || printf '0')" -lt "$end" ]; do
            if [ -t 0 ]; then
              ch=$(dd bs=1 count=1 2>/dev/null || true)
              case "$ch" in q|Q) exit 0 ;; esac
            fi
            sleep 0.1
          done
        done
        """
    }

    private func resolve(path rawPath: String, root: URL, allowRoot: Bool) throws -> URL {
        let normalized = normalizedTerminalPath(rawPath)
        if normalized == "/" {
            guard allowRoot else { throw LocalAlpineError.invalidPath(rawPath) }
            return root
        }

        if let mountedURL = LocalAlpineMountStore.resolvedWorkspaceURL(for: normalized) {
            return mountedURL
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
        timeoutSeconds: TimeInterval?,
        onSessionStart: (@MainActor @Sendable (Int?) -> Void)?,
        onOutput: @escaping @MainActor @Sendable (String) -> Void
    ) async -> LocalAlpineCommandResult? {
        let sessionID = await LocalAlpineNativeRuntime.shared.startSession(
            LocalAlpineNativeCommand(
                command: "",
                cwd: runtimeCWD,
                rootArchiveURL: rootArchiveURL,
                workspaceURL: workspaceURL,
                mountsConfiguration: LocalAlpineMountStore.runtimeMountsConfiguration()
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
        let deadline = timeoutSeconds.map { Date().addingTimeInterval(max(1, $0)) }

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
            if let deadline = deadline, Date() >= deadline {
                _ = LocalAlpineNativeRuntime.shared.interruptSession(sessionID: sessionID)
                let parsed = parseStreamingCommandOutput(rawOutput, markerPrefix: markerPrefix)
                let timedOutOutput = trimTrailingNewlines(parsed.rawOutput)
                let suffix = "[Command timed out after \(Int(max(1, timeoutSeconds ?? 0)))s]"
                let output = timedOutOutput.isEmpty ? suffix : "\(timedOutOutput)\n\(suffix)"
                return commandResult(rawOutput: output, exitCode: 124)
            }

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

    private func runtimeRootFSDataDirectory() throws -> URL {
        let workspaceURL = try ensureWorkspaceDirectory()
        if let rootArchiveURL = bundledRootFSURL() {
            let runtimeRootFSURL = try ensureRuntimeRootFSURL(from: rootArchiveURL, workspaceURL: workspaceURL)
            guard runtimeRootFSURL.pathExtension == "fakefs" else {
                throw LocalAlpineError.commandFailed("Local Alpine rootfs is not a writable fakefs directory.")
            }
            let dataURL = runtimeRootFSURL.appendingPathComponent("data", isDirectory: true)
            guard fileManager.fileExists(atPath: dataURL.path) else {
                throw LocalAlpineError.commandFailed("Local Alpine rootfs data directory is missing.")
            }
            return dataURL.standardizedFileURL
        }

        let dataURL = workspaceURL
            .appendingPathComponent("rootfs.fakefs", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        guard fileManager.fileExists(atPath: dataURL.path) else {
            throw LocalAlpineError.commandFailed("Local Alpine rootfs data directory is missing.")
        }
        return dataURL.standardizedFileURL
    }

    private func hostRootFSURL(
        for rootPath: String,
        dataRoot: URL,
        allowRoot: Bool
    ) throws -> URL {
        let normalized = try normalizedRootFSPath(rootPath)
        guard allowRoot || normalized != "/" else {
            throw LocalAlpineError.invalidPath(rootPath)
        }
        let relativePath = normalized == "/" ? "" : String(normalized.dropFirst())
        let url = relativePath.isEmpty
            ? dataRoot
            : dataRoot.appendingPathComponent(relativePath, isDirectory: false)
        let standardizedRoot = dataRoot.standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath == standardizedRoot
            || standardizedPath.hasPrefix(standardizedRoot + "/") else {
            throw LocalAlpineError.invalidPath(rootPath)
        }
        return url
    }

    private func rootFSListCommand(path: String, includeHidden: Bool) -> String {
        let hiddenGuard = includeHidden ? "" : """
          case "$name" in .*) return ;; esac
        """
        return """
        requested_target=\(shellSingleQuoted(path))
        target="$requested_target"
        if [ "$target" = "/" ]; then
          target=/
        elif [ "$target" = "" ]; then
          target=/
        fi
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          printf 'IEXA_ROOTFS_ERROR\\tPath does not exist: %s\\n' "$requested_target" >&2
          exit 20
        fi
        if [ "$target" != "/" ] && [ ! -d "$target" ]; then
          resolved_target=$(readlink -f "$target" 2>/dev/null || true)
          if [ -n "$resolved_target" ] && [ -d "$resolved_target" ]; then
            target="$resolved_target"
          else
            printf 'IEXA_ROOTFS_ERROR\\tNot a directory: %s\\n' "$requested_target" >&2
            exit 20
          fi
        fi
        printf 'IEXA_ROOTFS_LIST_BEGIN\\n'
        emit_rootfs_entry() {
          entry=$1
          [ -e "$entry" ] || [ -L "$entry" ] || return
          name=${entry##*/}
          case "$name" in .|..) return ;; esac
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
        }
        if [ "$target" = "/" ]; then
          for entry in /* /.[!.]* /..?*; do
            emit_rootfs_entry "$entry"
          done
        else
          for entry in "$target"/* "$target"/.[!.]* "$target"/..?*; do
            emit_rootfs_entry "$entry"
          done
        fi
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

        if let previewCommand = managedPythonHTTPServerCommand(for: trimmed) {
            return previewCommand
        }

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

        return protectDNSVersionChecks(in: protectSlowNPMVersionChecks(in: rewriteApkNodeAlias(in: command)))
    }

    private func managedPythonHTTPServerCommand(for command: String) -> String? {
        let pattern = #"(?i)\bpython(?:3(?:\.\d+)?)?\s+-m\s+http[.]server\b"#
        guard command.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        let invocation = pythonHTTPServerInvocation(in: command)
        let directory = invocation?.directory ?? "."
        let port = invocation?.port ?? 8000
        return "iexa-serve \(shellSingleQuoted(directory)) \(port)"
    }

    private func pythonHTTPServerInvocation(in command: String) -> (directory: String, port: Int)? {
        let words = shellWordsForSimpleCommand(command)
        guard !words.isEmpty else { return nil }

        var prefixDirectory: String?
        var searchStart = words.startIndex
        if words.count >= 4,
           words[0] == "cd",
           words[2] == "&&" {
            prefixDirectory = words[1]
            searchStart = 3
        }

        guard let moduleIndex = words[searchStart...].firstIndex(where: { $0.lowercased() == "http.server" }) else {
            return nil
        }

        var directory = "."
        var port: Int?
        var index = words.index(after: moduleIndex)
        while index < words.endIndex {
            let word = words[index]
            if word == "--directory" || word == "-d" {
                let valueIndex = words.index(after: index)
                if valueIndex < words.endIndex {
                    directory = words[valueIndex]
                    index = words.index(after: valueIndex)
                    continue
                }
            }
            if port == nil,
               let candidate = Int(word),
               (1...65_535).contains(candidate) {
                port = min(max(candidate, 1024), 65_535)
            }
            index = words.index(after: index)
        }

        if directory == ".", let prefixDirectory {
            directory = prefixDirectory
        } else if let prefixDirectory, !directory.hasPrefix("/") {
            directory = joinedShellPath(prefixDirectory, directory)
        }
        return (directory, port ?? 8000)
    }

    private func joinedShellPath(_ base: String, _ child: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.hasPrefix("/") {
            return "/" + [trimmedBase, trimmedChild].filter { !$0.isEmpty }.joined(separator: "/")
        }
        return [trimmedBase, trimmedChild].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private func shellWordsForSimpleCommand(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character == " " || character == "\t" || character == "\n" {
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(character)
        }
        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private func hasStandaloneBackgroundAmpersand(_ command: String) -> Bool {
        var escaped = false
        var inSingleQuote = false
        var inDoubleQuote = false
        let characters = Array(command)

        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "'", !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if character == Character("\""), !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            guard character == "&", !inSingleQuote, !inDoubleQuote else {
                continue
            }
            let previousIsAmpersand = index > characters.startIndex && characters[characters.index(before: index)] == "&"
            let nextIndex = characters.index(after: index)
            let nextIsAmpersand = nextIndex < characters.endIndex && characters[nextIndex] == "&"
            if !previousIsAmpersand && !nextIsAmpersand {
                return true
            }
        }

        return false
    }

    private func bootstrappedShellCommand(for command: String) -> String {
        let script = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return command }
        let customEnvironmentExports = LocalAlpineEnvironmentStore.shared.shellExportScript()
        return """
        iexa_apply_compat_env() {
          export LANG="${LANG:-C.UTF-8}"
          export LC_ALL="${LC_ALL:-C.UTF-8}"
          export NO_COLOR="${NO_COLOR:-1}"
          export PAGER="${PAGER:-less}"
          export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
          export GOMAXPROCS="${GOMAXPROCS:-2}"
          export UV_LINK_MODE="${UV_LINK_MODE:-symlink}"
        }
        iexa_apply_compat_env
        iexa_refresh_toolchain_env() {
          _iexa_toolchain_bin=""
          for candidate in /usr/aarch64-alpine-linux-musl/bin /usr/i586-alpine-linux-musl/bin /usr/i686-alpine-linux-musl/bin /usr/x86_64-alpine-linux-musl/bin; do
            if [ -d "$candidate" ]; then
              _iexa_toolchain_bin="$candidate"
              break
            fi
          done
          _iexa_base_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          if [ -n "$_iexa_toolchain_bin" ]; then
            _iexa_base_path="$_iexa_base_path:$_iexa_toolchain_bin"
          fi
          export PATH="$_iexa_base_path:${PATH:-}"
          if [ -n "$_iexa_toolchain_bin" ]; then
            export COMPILER_PATH="$_iexa_toolchain_bin:${COMPILER_PATH:-}"
          fi
        }
        iexa_refresh_toolchain_env
        if [ -f /etc/profile ]; then
          . /etc/profile >/dev/null 2>&1 || true
        fi
        iexa_apply_compat_env
        iexa_refresh_toolchain_env
        \(customEnvironmentExports)
        iexa_bootstrap_preview_helpers() {
          _iexa_bootstrap_bin=/tmp/iexa-bootstrap-bin
          _iexa_bootstrap_version=2026-07-18.3
          mkdir -p "$_iexa_bootstrap_bin" 2>/dev/null || return 0
          if [ -x "$_iexa_bootstrap_bin/iexa-open" ] && [ -x "$_iexa_bootstrap_bin/iexa-serve" ] && [ -x "$_iexa_bootstrap_bin/lsof" ] && [ -x "$_iexa_bootstrap_bin/netstat" ] && [ -x "$_iexa_bootstrap_bin/ping" ] && [ -x "$_iexa_bootstrap_bin/top" ] && [ -x "$_iexa_bootstrap_bin/nslookup" ] && [ "$(cat "$_iexa_bootstrap_bin/.iexa-bootstrap-version" 2>/dev/null)" = "$_iexa_bootstrap_version" ]; then
            export PATH="$_iexa_bootstrap_bin:${PATH:-}"
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
        to_iexa_resource() {
          case "$1" in
            http://*|https://*|about:*|file://*|iexa://*) printf '%s\\n' "$1" ;;
            /mnt/iexa/*)
              rel="${1#/mnt/iexa/}"
              case "$rel" in
                shared/*|skills/*|memory/*|mounts/*|attachments/*)
                  host="${rel%%/*}"
                  path="${rel#*/}"
                  printf 'iexa://%s/%s\\n' "$host" "$path"
                  ;;
                *)
                  printf 'iexa://workspace/%s\\n' "$rel"
                  ;;
              esac
              ;;
            /mnt/iexa) printf 'iexa://workspace/\\n' ;;
            /*) printf '%s\\n' "$1" ;;
            *)
              resolved=$(readlink -f "$1" 2>/dev/null || true)
              if [ -n "$resolved" ]; then
                to_iexa_resource "$resolved"
              else
                printf '%s\\n' "$1"
              fi
              ;;
          esac
        }
        for target in "$@"; do
          normalized=$(to_iexa_resource "$target")
          case "$normalized" in
            http://*|https://*|about:*|file://*|iexa://*|/*)
              emit_open_marker "$normalized"
              printf 'Opened in Iexa preview: %s\\n' "$normalized"
              ;;
            *)
              printf 'iexa-open: not a URL or path: %s\\n' "$target" >&2
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
        runtime_dir=/tmp/iexa-serve
        mkdir -p "$runtime_dir"
        if [ "${1:-}" = "stop" ] || [ "${1:-}" = "--stop" ]; then
          stop_target=${2:-all}
          is_managed_http_pid() {
            [ -n "${1:-}" ] || return 1
            if [ -r "/proc/$1/cmdline" ]; then
              tr '\\000' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -Eq 'python3? -m http[.]server|busybox .*httpd|httpd' && return 0
              return 1
            fi
            return 0
          }
          stop_one() {
            stop_port="$1"
            stop_pidfile="$runtime_dir/$stop_port.pid"
            stop_dirfile="$runtime_dir/$stop_port.dir"
            if [ ! -f "$stop_pidfile" ]; then
              printf 'No managed Iexa preview server on port %s.\\n' "$stop_port"
              return 1
            fi
            stop_pid=$(cat "$stop_pidfile" 2>/dev/null || true)
            if [ -n "$stop_pid" ] && kill -0 "$stop_pid" 2>/dev/null; then
              if is_managed_http_pid "$stop_pid"; then
                kill "$stop_pid" 2>/dev/null || true
                printf 'Stopped Iexa preview server on port %s.\\n' "$stop_port"
              else
                printf 'Refused to stop non-preview process from stale pidfile on port %s.\\n' "$stop_port" >&2
                return 1
              fi
            else
              printf 'Removed stale Iexa preview pidfile for port %s.\\n' "$stop_port"
            fi
            rm -f "$stop_pidfile" "$stop_dirfile"
            return 0
          }
          stopped=0
          if [ "$stop_target" = "all" ]; then
            for stop_pidfile in "$runtime_dir"/*.pid; do
              [ -e "$stop_pidfile" ] || continue
              stop_port=${stop_pidfile##*/}
              stop_port=${stop_port%.pid}
              stop_one "$stop_port" && stopped=1
            done
            [ "$stopped" -eq 1 ] || printf 'No managed Iexa preview servers are running.\\n'
            exit 0
          fi
          case "$stop_target" in
            ''|*[!0-9]*)
              printf 'iexa-serve stop: port must be a number or all.\\n' >&2
              exit 1
              ;;
          esac
          stop_one "$stop_target"
          exit $?
        fi
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
        print_urls() {
          token=$(date +%s 2>/dev/null || printf '%s' "$$")
          url="http://localhost:$1/?iexa_preview=$token"
          printf 'Preview URL: %s\\n' "$url"
          printf 'Loopback URL: http://127.0.0.1:%s/?iexa_preview=%s\\n' "$1" "$token"
          printf '访问地址: %s\\n' "$url"
          emit_open_marker "$url"
        }
        pid_alive() {
          [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
        }
        socket_port_in_use() {
          if [ -r /proc/net/tcp ]; then
            port_hex=$(printf '%04X' "$1" 2>/dev/null || true)
            if [ -n "$port_hex" ]; then
              awk -v p=":$port_hex" 'tolower($2) ~ tolower(p) && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp 2>/dev/null && return 0
              [ -r /proc/net/tcp6 ] && awk -v p=":$port_hex" 'tolower($2) ~ tolower(p) && $4 == "0A" { found=1 } END { exit found ? 0 : 1 }' /proc/net/tcp6 2>/dev/null && return 0
              return 1
            fi
          fi
          if command -v nc >/dev/null 2>&1; then
            if command -v timeout >/dev/null 2>&1; then
              timeout 1 nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
            else
              nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
            fi
            return 1
          fi
          return 2
        }
        server_ready() {
          socket_port_in_use "$1"
          socket_status=$?
          [ "$socket_status" -eq 0 ] && return 0
          if command -v python3 >/dev/null 2>&1; then
            python3 - "$1" <<'PY' >/dev/null 2>&1 && return 0
        import socket
        import sys

        sock = socket.socket()
        sock.settimeout(0.5)
        sock.connect(("127.0.0.1", int(sys.argv[1])))
        sock.close()
        PY
          fi
          return "$socket_status"
        }
        existing_server_for_dir() {
          candidate_port="$1"
          candidate_pidfile="$runtime_dir/$candidate_port.pid"
          candidate_dirfile="$runtime_dir/$candidate_port.dir"
          [ -f "$candidate_pidfile" ] || return 1
          candidate_pid=$(cat "$candidate_pidfile" 2>/dev/null || true)
          pid_alive "$candidate_pid" || return 1
          candidate_dir=$(cat "$candidate_dirfile" 2>/dev/null || true)
          if [ "$candidate_dir" = "$dir" ]; then
            printf 'Iexa local preview server already running.\\n'
            printf 'Directory: %s\\n' "$dir"
            printf 'PID: %s\\n' "$candidate_pid"
            print_urls "$candidate_port"
            exit 0
          fi
          socket_port_in_use "$candidate_port"
          socket_status=$?
          [ "$socket_status" -eq 1 ] && return 1
          return 1
        }
        port_in_use() {
          pidfile="$runtime_dir/$1.pid"
          if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null || true)
            pid_alive "$pid" && return 0
          fi
          socket_port_in_use "$1"
          socket_status=$?
          [ "$socket_status" -eq 0 ] && return 0
          [ "$socket_status" -eq 1 ] && return 1
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
        server_ready "$port" >/dev/null 2>&1 || true
        printf 'Iexa local preview server started.\\n'
        printf 'Directory: %s\\n' "$dir"
        printf 'PID: %s\\n' "$pid"
        print_urls "$port"
        IEXA_SERVE_FALLBACK
          cat > "$_iexa_bootstrap_bin/lsof" <<'IEXA_LSOF_FALLBACK'
        #!/bin/sh
        printf '%s is disabled in Iexa Local Alpine because it is unreliable in the embedded iSH runtime.\\n' "$(basename "$0")" >&2
        printf 'For localhost preview checks, use `nc -z 127.0.0.1 <port>` or inspect /proc/net/tcp.\\n' >&2
        exit 127
        IEXA_LSOF_FALLBACK
          cat > "$_iexa_bootstrap_bin/ping" <<'IEXA_PING_FALLBACK'
        \(localPingShimScript)
        IEXA_PING_FALLBACK
          cat > "$_iexa_bootstrap_bin/top" <<'IEXA_TOP_FALLBACK'
        \(localTopShimScript)
        IEXA_TOP_FALLBACK
          cat > "$_iexa_bootstrap_bin/nslookup" <<'IEXA_DNS_TIMEOUT_FALLBACK'
        #!/bin/sh
        _iexa_dns_tool=$(basename "$0")
        _iexa_dns_real=""
        _iexa_dns_wrapper_dir=$(dirname "$0")
        _iexa_dns_old_ifs="$IFS"
        IFS=:
        for _iexa_dns_dir in ${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}; do
          [ -n "$_iexa_dns_dir" ] || _iexa_dns_dir=.
          _iexa_dns_candidate="$_iexa_dns_dir/$_iexa_dns_tool"
          if [ -x "$_iexa_dns_candidate" ] && [ "$_iexa_dns_dir" != "$_iexa_dns_wrapper_dir" ] && [ "$_iexa_dns_dir" != "/usr/local/bin" ]; then
            _iexa_dns_real="$_iexa_dns_candidate"
            break
          fi
        done
        IFS="$_iexa_dns_old_ifs"
        if [ -z "$_iexa_dns_real" ]; then
          printf '/bin/sh: %s: not found\n' "$_iexa_dns_tool" >&2
          exit 127
        fi
        case "${1:-}" in
          --version|-version|version|-v|--help|-h)
            printf '%s is available through Iexa Local Alpine DNS wrapper.\n' "$_iexa_dns_tool"
            printf 'Real command: %s\n' "$_iexa_dns_real"
            printf 'DNS queries are bounded to 120 seconds.\n'
            exit 0
            ;;
        esac
        if command -v timeout >/dev/null 2>&1; then
          timeout 120 "$_iexa_dns_real" "$@"
          _iexa_dns_status=$?
        else
          "$_iexa_dns_real" "$@"
          _iexa_dns_status=$?
        fi
        case "$_iexa_dns_status" in
          124|137|143)
            printf '\nIEXA_DNS_TIMEOUT: %s exceeded 120 seconds in Local Alpine.\n' "$_iexa_dns_tool" >&2
            ;;
        esac
        exit "$_iexa_dns_status"
        IEXA_DNS_TIMEOUT_FALLBACK
          for tool in dig host drill; do
            _iexa_dns_real=""
            _iexa_dns_wrapper_dir="$_iexa_bootstrap_bin"
            _iexa_dns_old_ifs="$IFS"
            IFS=:
            for _iexa_dns_dir in ${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}; do
              [ -n "$_iexa_dns_dir" ] || _iexa_dns_dir=.
              _iexa_dns_candidate="$_iexa_dns_dir/$tool"
              if [ -x "$_iexa_dns_candidate" ] && [ "$_iexa_dns_dir" != "$_iexa_dns_wrapper_dir" ] && [ "$_iexa_dns_dir" != "/usr/local/bin" ]; then
                _iexa_dns_real="$_iexa_dns_candidate"
                break
              fi
            done
            IFS="$_iexa_dns_old_ifs"
            if [ -n "$_iexa_dns_real" ]; then
              cp "$_iexa_bootstrap_bin/nslookup" "$_iexa_bootstrap_bin/$tool" 2>/dev/null || true
            else
              rm -f "$_iexa_bootstrap_bin/$tool" 2>/dev/null || true
            fi
          done
          cp "$_iexa_bootstrap_bin/lsof" "$_iexa_bootstrap_bin/netstat" 2>/dev/null || true
          chmod +x "$_iexa_bootstrap_bin/iexa-open" "$_iexa_bootstrap_bin/iexa-serve" "$_iexa_bootstrap_bin/lsof" "$_iexa_bootstrap_bin/netstat" "$_iexa_bootstrap_bin/ping" "$_iexa_bootstrap_bin/top" "$_iexa_bootstrap_bin/nslookup" 2>/dev/null || true
          for tool in dig host drill; do
            [ -x "$_iexa_bootstrap_bin/$tool" ] && chmod +x "$_iexa_bootstrap_bin/$tool" 2>/dev/null || true
          done
          mkdir -p /usr/local/bin 2>/dev/null || true
          for tool in nslookup dig host drill; do
            if [ -x "$_iexa_bootstrap_bin/$tool" ]; then
              cp "$_iexa_bootstrap_bin/$tool" "/usr/local/bin/$tool" 2>/dev/null || true
              chmod +x "/usr/local/bin/$tool" 2>/dev/null || true
            fi
          done
          printf '%s\\n' "$_iexa_bootstrap_version" > "$_iexa_bootstrap_bin/.iexa-bootstrap-version" 2>/dev/null || true
          export PATH="$_iexa_bootstrap_bin:${PATH:-}"
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
        npm() {
          _iexa_npm="$(iexa_find_executable npm 2>/dev/null || true)"
          if [ -z "$_iexa_npm" ]; then
            printf '/bin/sh: npm: not found\n' >&2
            return 127
          fi
          export npm_config_audit=false
          export npm_config_fund=false
          export npm_config_progress=false
          export npm_config_update_notifier=false
          export npm_config_fetch_timeout=15000
          export npm_config_fetch_retries=1
          export npm_config_jobs=1
          export npm_config_maxsockets=2
          case "${1:-}" in
            install|i|ci|update)
              if command -v timeout >/dev/null 2>&1; then
                timeout 240 "$_iexa_npm" --no-audit --no-fund --no-progress "$@"
                status=$?
              else
                "$_iexa_npm" --no-audit --no-fund --no-progress "$@"
                status=$?
              fi
              case "$status" in
                124|137|143)
                  printf '\\nIEXA_NPM_TIMEOUT: npm command exceeded 240 seconds.\\n' >&2
                  printf 'Try a smaller dependency, switch the npm registry mirror, or use apk packages when available.\\n' >&2
                  ;;
              esac
              return "$status"
              ;;
            *)
              "$_iexa_npm" "$@"
              ;;
          esac
        }
        iexa_refresh_dns() {
          cat > /etc/resolv.conf <<'EOF'
        # managed by Iexa Local Alpine
        nameserver 223.5.5.5
        nameserver 119.29.29.29
        nameserver 1.1.1.1
        options timeout:2 attempts:3
        EOF
        }
        iexa_repair_toolchain_links() {
          arch_bin=""
          for candidate in /usr/aarch64-alpine-linux-musl/bin /usr/i586-alpine-linux-musl/bin /usr/i686-alpine-linux-musl/bin /usr/x86_64-alpine-linux-musl/bin; do
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
              iexa_refresh_toolchain_env
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

    private func protectDNSVersionChecks(in command: String) -> String {
        var rewritten = command
        let replacements = [
            (#"(?<![\w./-])(nslookup|dig|host|drill)\s+--version(?![\w-])"#, "iexa_dns_version $1"),
            (#"(?<![\w./-])(nslookup|dig|host|drill)\s+-version(?![\w-])"#, "iexa_dns_version $1"),
            (#"(?<![\w./-])(nslookup|dig|host|drill)\s+-v(?![\w-])"#, "iexa_dns_version $1")
        ]
        for (pattern, replacement) in replacements {
            rewritten = rewritten.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        guard rewritten != command else { return command }
        return """
        iexa_dns_version() {
          tool="$1"
          path="$(command -v "$tool" 2>/dev/null || true)"
          if [ -z "$path" ]; then
            echo "missing: $tool"
            return 127
          fi
          echo "$tool is available through Iexa Local Alpine."
          echo "Command: $path"
          echo "Version probing is skipped because BusyBox DNS tools may treat version flags as DNS queries."
          return 0
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

nonisolated enum LocalAlpineError: LocalizedError {
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
