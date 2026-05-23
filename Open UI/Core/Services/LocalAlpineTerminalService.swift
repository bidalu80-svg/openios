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
    private let bundledRootFSVersion = "3.19.9-lite.1"
    private let rootVersionFileName = ".iexa-rootfs-version"
    private let workspaceFolderName = "Iexa Alpine"
    private let sharedFolderName = "shared"
    private let maximumInlineRuntimeCommandBytes = 3_072

    private init() {}

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

    func writeFile(data: Data, fileName: String, destinationPath: String) async throws {
        let root = try ensureSharedWorkspaceDirectory()
        let directory = try resolve(path: destinationPath, root: root, allowRoot: true)
        let safeName = try sanitizedFileName(fileName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(safeName), options: .atomic)
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
        let materialized = await materializedRuntimeCommandIfNeeded(runtimeCommand)
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
        let versionURL = workspaceURL.appendingPathComponent(rootVersionFileName)
        if fileManager.fileExists(atPath: dataURL.path),
           fileManager.fileExists(atPath: metadataURL.path),
           storedRootFSVersion(at: versionURL) == bundledRootFSVersion {
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
        return writableURL.standardizedFileURL
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
        target=\(shellSingleQuoted(path))
        if [ ! -d "$target" ]; then
          printf 'IEXA_ROOTFS_ERROR\\tNot a directory: %s\\n' "$target" >&2
          exit 20
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
        if line == "IEXA_ROOTFS_LIST_BEGIN"
            || line == "IEXA_ROOTFS_LIST_END"
            || line == "IEXA_ROOTFS_B64_BEGIN"
            || line == "IEXA_ROOTFS_B64_END" {
            return nil
        }
        if line.contains("IEXA_ROOTFS_ENTRY\t") || line.contains("IEXA_ROOTFS_ENTRY\\t") {
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
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
        if [ -f /etc/profile ]; then
          . /etc/profile >/dev/null 2>&1 || true
        fi
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
        iexa_refresh_dns() {
          cat > /etc/resolv.conf <<'EOF'
        nameserver 1.1.1.1
        nameserver 8.8.8.8
        nameserver 223.5.5.5
        options timeout:2 attempts:3
        EOF
        }
        apk() {
          case "${1:-}" in
            add|fix|upgrade|update)
              attempts=0
              while :; do
                iexa_refresh_dns
                if command apk "$@"; then
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
              if command apk "$@"; then
                status=0
              else
                status=$?
              fi
              ;;
          esac
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
