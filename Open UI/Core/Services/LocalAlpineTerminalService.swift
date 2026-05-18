import Foundation
import os.log

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

actor LocalAlpineTerminalService {
    static let shared = LocalAlpineTerminalService()

    private let logger = Logger(subsystem: "com.openui", category: "LocalAlpine")
    private let fileManager = FileManager.default
    private let rootArchiveName = "iexa-alpine-rootfs.fakefs"
    private let workspaceFolderName = "Iexa Alpine"
    private let sharedFolderName = "shared"

    private init() {}

    func status() -> LocalAlpineStatus {
        LocalAlpineStatus(
            isRuntimeLinked: LocalAlpineNativeRuntime.shared.isLinked,
            isRootFSBundled: bundledRootFSURL() != nil,
            rootArchiveName: rootArchiveName,
            workspacePath: "Documents/\(workspaceFolderName)/\(sharedFolderName)"
        )
    }

    func listFiles(path: String) async throws -> [TerminalFileItem] {
        let root = try ensureSharedWorkspaceDirectory()
        let directory = try resolve(path: path, root: root, allowRoot: true)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
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

    func createFolder(path: String) async throws {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func deleteItem(path: String) async throws {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func readFile(path: String) async throws -> Data {
        let root = try ensureSharedWorkspaceDirectory()
        let url = try resolve(path: path, root: root, allowRoot: false)
        return try Data(contentsOf: url)
    }

    func writeFile(data: Data, fileName: String, destinationPath: String) async throws {
        let root = try ensureSharedWorkspaceDirectory()
        let directory = try resolve(path: destinationPath, root: root, allowRoot: true)
        let safeName = try sanitizedFileName(fileName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(safeName), options: .atomic)
    }

    func execute(command: String, cwd: String, stdinInput: String? = nil) async -> LocalAlpineCommandResult {
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
        } catch {
            return LocalAlpineCommandResult(
                command: trimmed,
                output: "Local Alpine rootfs could not be prepared for writable local execution: \(error.localizedDescription)",
                exitCode: 127,
                interactiveRequest: nil
            )
        }

        let runtimeCWD = normalizedRuntimePath(cwd)
        let compatibleCommand = compatibilityCommand(for: trimmed)
        let bootstrappedCommand = bootstrappedShellCommand(for: compatibleCommand)
        let runtimeCommand = stdinInput.map {
            wrappedCommandForInteractiveInput(command: bootstrappedCommand, stdinInput: $0)
        } ?? bootstrappedCommand
        let result = await LocalAlpineNativeRuntime.shared.execute(
            LocalAlpineNativeCommand(
                command: runtimeCommand,
                cwd: runtimeCWD,
                rootArchiveURL: runtimeRootFSURL,
                workspaceURL: workspaceURL
            )
        )
        return LocalAlpineCommandResult(command: trimmed, output: result.output, exitCode: result.exitCode, interactiveRequest: nil)
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
        if fileManager.fileExists(atPath: dataURL.path),
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
        return writableURL.standardizedFileURL
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
            let unsupportedOption = parts.dropLast().contains { $0.hasPrefix("-") && !passthroughOptions.contains($0) }
            guard !unsupportedOption, let url = parts.last, !url.hasPrefix("-") else { return command }

            let escapedURL = shellSingleQuoted(url)
            return """
            if command -v curl >/dev/null 2>&1; then
              \(command)
            else
              wget -qO- \(escapedURL)
            fi
            """
        }

        return rewriteApkNodeAlias(in: command)
    }

    private func bootstrappedShellCommand(for command: String) -> String {
        let script = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return command }
        return """
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
        if [ -f /etc/profile ]; then
          . /etc/profile >/dev/null 2>&1 || true
        fi
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
        apk() {
          command apk "$@"
          status=$?
          case "${1:-}" in
            add|fix|upgrade)
              hash -r 2>/dev/null || true
              export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
              ;;
          esac
          return "$status"
        }
        hash -r 2>/dev/null || true
        \(script)
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

    private func sanitizedFileName(_ rawName: String) throws -> String {
        let name = URL(fileURLWithPath: rawName).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else {
            throw LocalAlpineError.invalidPath(rawName)
        }
        return name
    }
}

enum LocalAlpineError: LocalizedError {
    case documentsUnavailable
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "Documents directory is unavailable."
        case .invalidPath(let path):
            return "Invalid local path: \(path)"
        }
    }
}
