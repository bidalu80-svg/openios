import Foundation

struct LocalWorkspaceAgentResult: Sendable {
    let didExecute: Bool
    let summary: String
}

actor LocalWorkspaceAgentService {
    static let shared = LocalWorkspaceAgentService()

    private let fileManager = FileManager.default
    private let workspaceFolderName = "Iexa Workspace"
    private let maxOperationsPerResponse = 80
    private let maxPreviewBytes = 40_000

    private init() {}

    func executeBlocks(in content: String) async -> LocalWorkspaceAgentResult {
        let blocks = extractInstructionBlocks(from: content)
        guard !blocks.isEmpty else {
            return LocalWorkspaceAgentResult(didExecute: false, summary: "")
        }

        var operations: [WorkspaceOperation] = []
        var lines: [String] = []

        for block in blocks {
            do {
                let blockOperations = try parseOperations(fromJSONString: block)
                operations.append(contentsOf: blockOperations)
            } catch {
                lines.append("- 指令解析失败：\(error.localizedDescription)")
            }
        }

        if operations.isEmpty {
            let summary = (["本地工作区没有执行任何操作。"] + lines).joined(separator: "\n")
            return LocalWorkspaceAgentResult(didExecute: true, summary: summary)
        }

        let trimmedOperations = Array(operations.prefix(maxOperationsPerResponse))
        let skippedCount = max(0, operations.count - trimmedOperations.count)
        let root: URL

        do {
            root = try ensureWorkspaceDirectory()
        } catch {
            let summary = "本地工作区初始化失败：\(error.localizedDescription)"
            return LocalWorkspaceAgentResult(didExecute: true, summary: summary)
        }

        lines.insert("本地工作区执行结果", at: 0)
        lines.append("工作区：Documents/\(workspaceFolderName)")

        for operation in trimmedOperations {
            lines.append(execute(operation, root: root))
        }

        if skippedCount > 0 {
            lines.append("- 已跳过 \(skippedCount) 个多余操作，避免一次回复写入过多文件。")
        }

        return LocalWorkspaceAgentResult(didExecute: true, summary: lines.joined(separator: "\n"))
    }

    private func extractInstructionBlocks(from content: String) -> [String] {
        var blocks: [String] = []
        let nsContent = content as NSString

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for match in matches where match.numberOfRanges >= 3 {
                let info = nsContent.substring(with: match.range(at: 1)).lowercased()
                let body = nsContent.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if info.contains("iexa_workspace")
                    || (info.trimmingCharacters(in: .whitespacesAndNewlines) == "json" && body.contains("\"iexa_workspace\"")) {
                    blocks.append(body)
                }
            }
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"<iexa_workspace>([\s\S]*?)</iexa_workspace>"#, options: [.caseInsensitive]) {
            let matches = tagRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            for match in matches where match.numberOfRanges >= 2 {
                blocks.append(nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return blocks
    }

    private func parseOperations(fromJSONString jsonString: String) throws -> [WorkspaceOperation] {
        guard let data = jsonString.data(using: .utf8) else {
            throw WorkspaceAgentError.invalidJSON
        }

        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let operations = parseOperations(from: object)
        if operations.isEmpty {
            throw WorkspaceAgentError.noOperations
        }
        return operations
    }

    private func parseOperations(from object: Any) -> [WorkspaceOperation] {
        if let array = object as? [Any] {
            return array.flatMap { parseOperations(from: $0) }
        }

        guard let dict = object as? [String: Any] else { return [] }

        if let nested = dict["iexa_workspace"] ?? dict["operations"] {
            return parseOperations(from: nested)
        }

        if let files = dict["files"] as? [[String: Any]] {
            return files.compactMap { file in
                guard let path = file["path"] as? String else { return nil }
                let content = Self.workspaceContentPayload(from: file) ?? ""
                return WorkspaceOperation(action: .write, path: path, content: content)
            }
        }

        guard let rawAction = dict["action"] as? String,
              let action = WorkspaceAction(rawValueLike: rawAction)
        else { return [] }

        let path = (dict["path"] as? String)
            ?? (dict["file"] as? String)
            ?? (dict["folder"] as? String)
            ?? "."
        let content: String?
        switch action {
        case .write, .append:
            content = Self.workspaceContentPayload(from: dict) ?? ""
        case .search:
            content = (dict["query"] as? String)
                ?? (dict["pattern"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["content"] as? String)
        default:
            content = nil
        }

        return [WorkspaceOperation(action: action, path: path, content: content)]
    }

    private nonisolated static func workspaceContentPayload(from dict: [String: Any]) -> String? {
        if let base64 = (dict["content_base64"] as? String)
            ?? (dict["base64"] as? String),
           let data = Data(base64Encoded: base64),
           let content = String(data: data, encoding: .utf8) {
            return content
        }

        if let lines = (dict["content_lines"] as? [String])
            ?? (dict["code_lines"] as? [String])
            ?? (dict["lines"] as? [String]) {
            var content = lines.joined(separator: "\n")
            let shouldAppendNewline = (dict["append_newline"] as? Bool)
                ?? (dict["trailing_newline"] as? Bool)
                ?? true
            if shouldAppendNewline, !content.hasSuffix("\n") {
                content += "\n"
            }
            return content
        }

        return (dict["content"] as? String)
            ?? (dict["contents"] as? String)
            ?? (dict["text"] as? String)
            ?? (dict["body"] as? String)
            ?? (dict["code"] as? String)
    }

    private func execute(_ operation: WorkspaceOperation, root: URL) -> String {
        do {
            switch operation.action {
            case .mkdir:
                let url = try resolvePath(operation.path, root: root, allowRoot: false)
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return "- 已创建文件夹 `\(operation.path)`"

            case .write:
                let url = try resolvePath(operation.path, root: root, allowRoot: false)
                let parent = url.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                let content = preparedContent(operation.content ?? "", for: operation.path)
                try Data(content.utf8).write(to: url, options: .atomic)
                return "- 已写入文件 `\(operation.path)`（\(content.utf8.count) B）"

            case .append:
                let url = try resolvePath(operation.path, root: root, allowRoot: false)
                let parent = url.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                let content = preparedContent(operation.content ?? "", for: operation.path)
                if fileManager.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    handle.seekToEndOfFile()
                    handle.write(Data(content.utf8))
                    handle.closeFile()
                } else {
                    try Data(content.utf8).write(to: url, options: .atomic)
                }
                return "- 已追加文件 `\(operation.path)`（+\(content.utf8.count) B）"

            case .read:
                let url = try resolvePath(operation.path, root: root, allowRoot: false)
                let data = try Data(contentsOf: url)
                let previewData = data.prefix(maxPreviewBytes)
                let preview = String(data: previewData, encoding: .utf8) ?? "该文件不是可预览的 UTF-8 文本。"
                let truncated = data.count > maxPreviewBytes ? "\n...（内容过长，已截断预览）" : ""
                return "- 已读取 `\(operation.path)`：\n```text\n\(preview)\(truncated)\n```"

            case .list:
                let url = try resolvePath(operation.path, root: root, allowRoot: true)
                let children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                let names = children
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    .map { child -> String in
                        let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        return isDirectory ? "\(child.lastPathComponent)/" : child.lastPathComponent
                    }
                let label = operation.path == "." ? "根目录" : "`\(operation.path)`"
                return "- \(label)包含：\(names.isEmpty ? "空" : names.joined(separator: ", "))"

            case .search:
                let url = try resolvePath(operation.path, root: root, allowRoot: true)
                let query = operation.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !query.isEmpty else {
                    return "- 搜索失败：缺少 query/pattern。"
                }
                return search(query: query, at: url, root: root)

            case .delete:
                let url = try resolvePath(operation.path, root: root, allowRoot: false)
                guard fileManager.fileExists(atPath: url.path) else {
                    return "- 未找到 `\(operation.path)`，无需删除"
                }
                try fileManager.removeItem(at: url)
                return "- 已删除 `\(operation.path)`"
            }
        } catch {
            return "- `\(operation.path)` 执行失败：\(error.localizedDescription)"
        }
    }

    private nonisolated func preparedContent(_ content: String, for _: String) -> String {
        content
    }

    nonisolated static func visibleContent(from content: String) -> String {
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        var removalRanges: [NSRange] = []

        if let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n([\s\S]*?)```"#, options: [.caseInsensitive]) {
            let matches = regex.matches(in: content, range: fullRange)
            for match in matches where match.numberOfRanges >= 3 {
                let info = nsContent.substring(with: match.range(at: 1)).lowercased()
                let body = nsContent.substring(with: match.range(at: 2))
                if info.contains("iexa_workspace")
                    || (info.trimmingCharacters(in: .whitespacesAndNewlines) == "json"
                        && body.contains("\"iexa_workspace\"")) {
                    removalRanges.append(match.range)
                }
            }
        }

        if let tagRegex = try? NSRegularExpression(pattern: #"<iexa_workspace>[\s\S]*?</iexa_workspace>"#, options: [.caseInsensitive]) {
            removalRanges.append(contentsOf: tagRegex.matches(in: content, range: fullRange).map(\.range))
        }

        guard !removalRanges.isEmpty else {
            return content
        }

        let mutable = NSMutableString(string: content)
        for range in removalRanges.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: range, with: "")
        }

        let cleaned = (mutable as String)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "正在执行本地工作区操作..." : cleaned
    }

    private func ensureWorkspaceDirectory() throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw WorkspaceAgentError.documentsUnavailable
        }
        let root = documents.appendingPathComponent(workspaceFolderName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func resolvePath(_ rawPath: String, root: URL, allowRoot: Bool) throws -> URL {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")

        if path == "." || path == "/" || path.isEmpty {
            guard allowRoot else { throw WorkspaceAgentError.invalidPath(rawPath) }
            return root
        }

        guard !path.hasPrefix("/")
            && !path.hasPrefix("~")
            && !path.contains("://")
            && !path.contains(":")
            && !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw WorkspaceAgentError.invalidPath(rawPath) }

        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." }) else {
            throw WorkspaceAgentError.invalidPath(rawPath)
        }

        let target = parts.reduce(root) { partial, part in
            partial.appendingPathComponent(String(part))
        }.standardizedFileURL

        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard target.path.hasPrefix(prefix) else {
            throw WorkspaceAgentError.invalidPath(rawPath)
        }
        return target
    }

    private func search(query: String, at url: URL, root: URL) -> String {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let files: [URL]

        if isDirectory {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            files = enumerator?.compactMap { entry -> URL? in
                guard let fileURL = entry as? URL else { return nil }
                let values = try? fileURL.resourceValues(forKeys: Set<URLResourceKey>(keys))
                guard values?.isRegularFile == true else { return nil }
                if let size = values?.fileSize, size > maxPreviewBytes * 4 { return nil }
                return fileURL
            } ?? []
        } else {
            files = [url]
        }

        let loweredQuery = query.lowercased()
        var matches: [String] = []

        for fileURL in files.prefix(300) {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data.prefix(maxPreviewBytes * 4), encoding: .utf8) else {
                continue
            }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            for (index, line) in lines.enumerated() where line.lowercased().contains(loweredQuery) {
                matches.append("- `\(relativePath(fileURL, root: root)):\(index + 1)` \(String(line.prefix(180)))")
                if matches.count >= 30 { break }
            }
            if matches.count >= 30 { break }
        }

        if matches.isEmpty {
            return "- 未找到包含 `\(query)` 的内容。"
        }
        return "- 搜索 `\(query)` 找到 \(matches.count) 处：\n\(matches.joined(separator: "\n"))"
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}

private struct WorkspaceOperation {
    let action: WorkspaceAction
    let path: String
    let content: String?
}

private enum WorkspaceAction {
    case mkdir
    case write
    case append
    case read
    case list
    case search
    case delete

    init?(rawValueLike value: String) {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "mkdir", "createdirectory", "createfolder", "folder":
            self = .mkdir
        case "write", "writefile", "createfile", "save":
            self = .write
        case "append", "appendfile":
            self = .append
        case "read", "readfile", "open":
            self = .read
        case "list", "ls", "listdirectory", "listfolder":
            self = .list
        case "search", "grep", "findtext", "findinfiles":
            self = .search
        case "delete", "remove", "rm", "unlink":
            self = .delete
        default:
            return nil
        }
    }
}

private enum WorkspaceAgentError: LocalizedError {
    case documentsUnavailable
    case invalidJSON
    case noOperations
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "无法访问应用文档目录。"
        case .invalidJSON:
            return "JSON 内容无效。"
        case .noOperations:
            return "没有找到可执行的 workspace 操作。"
        case .invalidPath(let path):
            return "路径不安全或无效：\(path)"
        }
    }
}
