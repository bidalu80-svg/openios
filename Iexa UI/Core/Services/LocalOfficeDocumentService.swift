import Foundation
import UIKit

struct LocalOfficeDocumentResult: Sendable {
    let documentURL: URL
    let previewURLs: [URL]
    let draftURL: URL
    let contentType: String
    let documentType: String
    let title: String
    let summary: String
    let previewText: String

    var files: [ChatMessageFile] {
        var items = [
            ChatMessageFile(
                type: "file",
                url: documentURL.absoluteString,
                name: documentURL.lastPathComponent,
                contentType: contentType
            )
        ]
        for preview in previewURLs.prefix(6) {
            items.append(ChatMessageFile(
                type: "image",
                url: preview.absoluteString,
                name: preview.lastPathComponent,
                contentType: "image/png"
            ))
        }
        return items
    }

    var payload: [String: Any] {
        [
            "ok": true,
            "document_type": documentType,
            "title": title,
            "file_name": documentURL.lastPathComponent,
            "file_url": documentURL.absoluteString,
            "content_type": contentType,
            "preview_images": previewURLs.map(\.absoluteString),
            "draft_url": draftURL.absoluteString,
            "summary": summary,
            "preview_text": previewText
        ]
    }
}

struct LocalOfficeDeleteResult: Sendable {
    let deletedFileURL: URL
    let deletedFolderURL: URL
    let fileName: String
    let summary: String

    var payload: [String: Any] {
        [
            "ok": true,
            "deleted": true,
            "file_name": fileName,
            "deleted_file_url": deletedFileURL.absoluteString,
            "deleted_folder_url": deletedFolderURL.absoluteString,
            "summary": summary
        ]
    }
}

@MainActor
final class LocalOfficeDocumentService {
    static let shared = LocalOfficeDocumentService()

    private let fileManager = FileManager.default

    private init() {}

    func createExcel(
        from call: [String: Any],
        progress: LocalOfficeProgressHandler? = nil
    ) async throws -> LocalOfficeDocumentResult {
        let spec = ExcelSpec(call: call)
        await reportProgress(.parsedDemand, to: progress)
        let folder = try makeOutputFolder(prefix: "excel")
        let fileName = safeFileName(spec.fileName, fallback: "\(spec.title).xlsx", fileExtension: "xlsx")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")
        let previewURL = folder.appendingPathComponent("preview-1.png")

        let xlsx = try ExcelOpenXMLBuilder(spec: spec).build()
        try OfficeZipWriter(entries: xlsx).write(to: documentURL)
        try writeJSON(spec.normalizedDraft(original: call), to: draftURL)
        await reportProgress(.generatedFile, to: progress)
        try await renderExcelPreview(spec: spec, to: previewURL)
        await reportProgress(.generatedPreview, to: progress)

        return LocalOfficeDocumentResult(
            documentURL: documentURL,
            previewURLs: [previewURL],
            draftURL: draftURL,
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            documentType: "excel",
            title: spec.title,
            summary: "已生成 Excel：\(fileName)，共 \(spec.sheets.count) 个工作表。",
            previewText: spec.previewText
        )
    }

    func createPowerPoint(
        from call: [String: Any],
        progress: LocalOfficeProgressHandler? = nil
    ) async throws -> LocalOfficeDocumentResult {
        let spec = PresentationSpec(call: call)
        await reportProgress(.parsedDemand, to: progress)
        let folder = try makeOutputFolder(prefix: "ppt")
        let fileName = safeFileName(spec.fileName, fallback: "\(spec.title).pptx", fileExtension: "pptx")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")

        var renderedSlides: [RenderedSlide] = []
        for (index, slide) in spec.slides.enumerated() {
            let image = renderSlidePreview(slide: slide, index: index, theme: spec.theme)
            let url = folder.appendingPathComponent("slide-\(index + 1).png")
            try writePNG(image, to: url)
            renderedSlides.append(RenderedSlide(slide: slide, previewURL: url))
        }

        let pptx = try PowerPointOpenXMLBuilder(spec: spec, renderedSlides: renderedSlides).build()
        try OfficeZipWriter(entries: pptx).write(to: documentURL)
        try writeJSON(call, to: draftURL)
        await reportProgress(.generatedFile, to: progress)
        await reportProgress(.generatedPreview, to: progress)

        return LocalOfficeDocumentResult(
            documentURL: documentURL,
            previewURLs: renderedSlides.map(\.previewURL),
            draftURL: draftURL,
            contentType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            documentType: "ppt",
            title: spec.title,
            summary: "已生成 PPT：\(fileName)，共 \(spec.slides.count) 页。",
            previewText: spec.previewText
        )
    }

    func createWord(
        from call: [String: Any],
        progress: LocalOfficeProgressHandler? = nil
    ) async throws -> LocalOfficeDocumentResult {
        let spec = WordSpec(call: call)
        await reportProgress(.parsedDemand, to: progress)
        let folder = try makeOutputFolder(prefix: "word")
        let fileName = safeFileName(spec.fileName, fallback: "\(spec.title).docx", fileExtension: "docx")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")

        var previewURLs: [URL] = []
        let previewImages = WordPreviewRenderer.renderPages(spec: spec)
        for (index, image) in previewImages.enumerated() {
            let previewURL = folder.appendingPathComponent("preview-\(index + 1).png")
            try writePNG(image, to: previewURL)
            previewURLs.append(previewURL)
        }

        let visualPageURLs = spec.shouldEmbedPreviewPagesInWord ? previewURLs : []
        let docx = try WordOpenXMLBuilder(spec: spec, visualPageURLs: visualPageURLs).build()
        try OfficeZipWriter(entries: docx).write(to: documentURL)
        try writeJSON(call, to: draftURL)
        await reportProgress(.generatedFile, to: progress)
        await reportProgress(.generatedPreview, to: progress)

        let modeText = spec.shouldEmbedPreviewPagesInWord ? "视觉页模式，" : ""
        return LocalOfficeDocumentResult(
            documentURL: documentURL,
            previewURLs: previewURLs,
            draftURL: draftURL,
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            documentType: "word",
            title: spec.title,
            summary: "已生成 Word：\(fileName)，\(modeText)共 \(spec.sections.count) 个章节、\(previewURLs.count) 页预览。",
            previewText: spec.previewText
        )
    }

    func createPDF(
        from call: [String: Any],
        progress: LocalOfficeProgressHandler? = nil
    ) async throws -> LocalOfficeDocumentResult {
        let title = JSONValue.string(call["title"], fallback: "PDF 文档")
        await reportProgress(.parsedDemand, to: progress)
        let folder = try makeOutputFolder(prefix: "pdf")
        let fileName = safeFileName(JSONValue.string(call["file_name"]).nilIfEmpty, fallback: "\(title).pdf", fileExtension: "pdf")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")

        let render = existingOfficePDFRenderPlan(from: call) ?? PDFRenderPlan(call: call)
        let pages = render.pages
        guard !pages.isEmpty else {
            throw OfficeDocumentError.renderFailed
        }
        try PDFDocumentRenderer.write(images: pages, title: render.title, to: documentURL)
        try writeJSON(call, to: draftURL)
        await reportProgress(.generatedFile, to: progress)

        var previewURLs: [URL] = []
        for (index, image) in pages.enumerated() {
            let previewURL = folder.appendingPathComponent("preview-\(index + 1).png")
            try writePNG(image, to: previewURL)
            previewURLs.append(previewURL)
        }
        await reportProgress(.generatedPreview, to: progress)

        return LocalOfficeDocumentResult(
            documentURL: documentURL,
            previewURLs: previewURLs,
            draftURL: draftURL,
            contentType: "application/pdf",
            documentType: "pdf",
            title: render.title,
            summary: "已生成 PDF：\(fileName)，共 \(pages.count) 页。",
            previewText: render.previewText
        )
    }

    func deleteDocument(from call: [String: Any]) throws -> LocalOfficeDeleteResult {
        let root = try officeRootDirectory()
        let targetURL = try deleteTargetURL(from: call, root: root)
        let folderURL = try officeFolderForDeleteTarget(targetURL, root: root)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw OfficeDocumentError.deleteTargetNotFound
        }

        let deletedFileURL = primaryOfficeFile(in: folderURL) ?? targetURL
        let fileName = deletedFileURL.lastPathComponent.isEmpty
            ? folderURL.lastPathComponent
            : deletedFileURL.lastPathComponent
        try fileManager.removeItem(at: folderURL)

        return LocalOfficeDeleteResult(
            deletedFileURL: deletedFileURL,
            deletedFolderURL: folderURL,
            fileName: fileName,
            summary: "已删除本地 Office/PDF 文件：\(fileName)。"
        )
    }

    private func makeOutputFolder(prefix: String) throws -> URL {
        let root = try officeRootDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = root.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func officeRootDirectory() throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw OfficeDocumentError.documentsUnavailable
        }
        let url = documents.appendingPathComponent("Iexa Workspace/Office Agent", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func safeFileName(_ raw: String?, fallback: String, fileExtension ext: String) -> String {
        let base = (raw?.isEmpty == false ? raw! : fallback)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withFallback = base.isEmpty ? fallback : base
        let ns = withFallback as NSString
        if ns.pathExtension.lowercased() == ext {
            return ns.lastPathComponent
        }
        return "\(ns.deletingPathExtension.isEmpty ? fallback : ns.deletingPathExtension).\(ext)"
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let normalized = JSONValue.normalized(object)
        let data = try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writePNG(_ image: UIImage, to url: URL) throws {
        guard let data = image.pngData() else {
            throw OfficeDocumentError.renderFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private func renderExcelPreview(spec: ExcelSpec, to url: URL) async throws {
        let image = ExcelPreviewRenderer.render(spec: spec)
        try writePNG(image, to: url)
    }

    private func reportProgress(
        _ phase: LocalOfficeProgressPhase,
        to progress: LocalOfficeProgressHandler?
    ) async {
        guard let progress else { return }
        await progress(phase)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func renderSlidePreview(slide: SlideSpec, index: Int, theme: PresentationTheme) -> UIImage {
        SlidePreviewRenderer.render(slide: slide, index: index, theme: theme)
    }

    private func existingOfficePDFRenderPlan(from call: [String: Any]) -> PDFRenderPlan? {
        let candidates = [
            JSONValue.string(call["source_file"]),
            JSONValue.string(call["source_url"]),
            JSONValue.string(call["input_file"]),
            JSONValue.string(call["input_url"]),
            JSONValue.string(call["file_url"]),
            JSONValue.string(call["from"])
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for raw in candidates {
            guard let url = localFileURL(from: raw) else { continue }
            let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let imageURLs = previewImageURLs(in: folder)
            let images = imageURLs.compactMap { UIImage(contentsOfFile: $0.path) }
            guard !images.isEmpty else { continue }
            let title = JSONValue.string(call["title"], fallback: url.deletingPathExtension().lastPathComponent)
            return PDFRenderPlan(
                title: title,
                previewText: "由本地文件预览转换：\(url.lastPathComponent)",
                pages: images
            )
        }
        return nil
    }

    private func localFileURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        if trimmed.hasPrefix("/") || trimmed.contains(":\\") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }

    private func deleteTargetURL(from call: [String: Any], root: URL) throws -> URL {
        let targetKeys = [
            "file_url",
            "source_url",
            "source_file",
            "input_url",
            "input_file",
            "url",
            "path",
            "file",
            "target",
            "from"
        ]
        for key in targetKeys {
            if let url = localFileURL(from: JSONValue.string(call[key])) {
                return url
            }
        }

        let nameKeys = ["file_name", "filename", "name", "title"]
        for key in nameKeys {
            if let folder = try folderMatchingOfficeTargetName(JSONValue.string(call[key]), root: root) {
                return folder
            }
        }

        return try latestOfficeFolder(in: root)
    }

    private func officeFolderForDeleteTarget(_ target: URL, root: URL) throws -> URL {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let targetURL = target.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        let targetPath = targetURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else {
            throw OfficeDocumentError.deleteTargetOutsideOfficeRoot
        }

        let relativePath = String(targetPath.dropFirst(prefix.count))
        guard let firstComponent = relativePath.split(separator: "/").first,
              !firstComponent.isEmpty else {
            throw OfficeDocumentError.deleteTargetOutsideOfficeRoot
        }
        return rootURL.appendingPathComponent(String(firstComponent), isDirectory: true)
    }

    private func latestOfficeFolder(in root: URL) throws -> URL {
        let folders = try officeFolders(in: root)
        guard let latest = folders.max(by: { lhs, rhs in
            officeFolderDate(lhs) < officeFolderDate(rhs)
        }) else {
            throw OfficeDocumentError.deleteTargetNotFound
        }
        return latest
    }

    private func folderMatchingOfficeTargetName(_ rawName: String, root: URL) throws -> URL? {
        let target = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let targetLower = target.lowercased()
        let targetBase = (target as NSString).deletingPathExtension.lowercased()
        let folders = try officeFolders(in: root).sorted {
            officeFolderDate($0) > officeFolderDate($1)
        }

        for folder in folders {
            if folder.lastPathComponent.lowercased() == targetLower {
                return folder
            }
            guard let children = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where isOfficeDocumentFile(child) {
                let childName = child.lastPathComponent.lowercased()
                let childBase = (child.lastPathComponent as NSString).deletingPathExtension.lowercased()
                if childName == targetLower || childBase == targetLower || childBase == targetBase {
                    return folder
                }
            }
        }
        return nil
    }

    private func officeFolders(in root: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
    }

    private func officeFolderDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate ?? .distantPast
    }

    private func primaryOfficeFile(in folder: URL) -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls.first(where: isOfficeDocumentFile)
    }

    private func isOfficeDocumentFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "xlsx", "xls", "pptx", "ppt", "docx", "doc", "pdf":
            return true
        default:
            return false
        }
    }

    private func previewImageURLs(in folder: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                return (name.hasPrefix("preview-") || name.hasPrefix("slide-")) && ext == "png"
            }
            .sorted { lhs, rhs in
                naturalIndex(lhs.lastPathComponent) < naturalIndex(rhs.lastPathComponent)
            }
    }

    private func naturalIndex(_ name: String) -> Int {
        let digits = name.compactMap { $0.isNumber ? $0 : nil }
        return Int(String(digits)) ?? Int.max
    }
}

private enum OfficeDocumentError: LocalizedError {
    case documentsUnavailable
    case renderFailed
    case invalidArchive
    case deleteTargetNotFound
    case deleteTargetOutsideOfficeRoot

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "无法访问 Documents 目录。"
        case .renderFailed:
            return "文档预览图生成失败。"
        case .invalidArchive:
            return "Office 文件打包失败。"
        case .deleteTargetNotFound:
            return "没有找到可删除的本地 Office/PDF 文件。"
        case .deleteTargetOutsideOfficeRoot:
            return "只能删除 Iexa 本地 Office 生成目录内的文件。"
        }
    }
}

private enum JSONValue {
    nonisolated static func normalized(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues(normalized)
        case let array as [Any]:
            return array.map(normalized)
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            return value.isFinite ? value : 0
        case let value as Float:
            return value.isFinite ? Double(value) : 0
        case let value as NSNumber:
            return value
        default:
            return String(describing: value)
        }
    }

    static func string(_ value: Any?, fallback: String = "") -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return fallback
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let array = value as? [Any] {
            return array.map { string($0) }.filter { !$0.isEmpty }
        }
        if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

private struct ExcelSpec: Sendable {
    let title: String
    let fileName: String?
    let theme: PresentationTheme
    let sheets: [ExcelSheetSpec]

    init(call: [String: Any]) {
        title = JSONValue.string(call["title"], fallback: "Excel 报表")
        fileName = JSONValue.string(call["file_name"]).nilIfEmpty
        theme = PresentationTheme(raw: call["theme"] as? [String: Any], hint: Self.themeHint(from: call))
        let rawSheets = JSONValue.array(call["sheets"])
        if rawSheets.isEmpty {
            sheets = [
                ExcelSheetSpec(
                    name: "Sheet1",
                    headers: JSONValue.stringArray(call["headers"]),
                    rows: ExcelSheetSpec.rows(from: call["rows"]),
                    notes: JSONValue.stringArray(call["notes"])
                )
            ]
        } else {
            sheets = rawSheets.enumerated().map { index, sheet in
                ExcelSheetSpec(
                    name: JSONValue.string(sheet["name"], fallback: "Sheet\(index + 1)"),
                    headers: JSONValue.stringArray(sheet["headers"]),
                    rows: ExcelSheetSpec.rows(from: sheet["rows"]),
                    notes: JSONValue.stringArray(sheet["notes"])
                )
            }
        }
    }

    var previewText: String {
        sheets.map { sheet in
            let header = "\(sheet.name)：\(sheet.headers.joined(separator: " | "))"
            let body = sheet.rows.prefix(8).map { row in row.joined(separator: " | ") }.joined(separator: "\n")
            return [header, body].filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func normalizedDraft(original: [String: Any]) -> [String: Any] {
        var draft = original
        draft["action"] = "office.create_excel"
        draft["title"] = title
        if let fileName {
            draft["file_name"] = fileName
        }
        draft["theme"] = theme.normalizedDraft
        draft["sheets"] = sheets.map { sheet in
            [
                "name": sheet.name,
                "headers": sheet.headers,
                "rows": sheet.rows,
                "notes": sheet.notes
            ] as [String: Any]
        }
        return draft
    }

    private static func themeHint(from call: [String: Any]) -> String {
        let sheetHints = JSONValue.array(call["sheets"]).prefix(3).flatMap { sheet in
            [
                JSONValue.string(sheet["name"]),
                JSONValue.string(sheet["title"]),
                JSONValue.string(sheet["style"]),
                JSONValue.string(sheet["note"]),
                JSONValue.string(sheet["notes"])
            ] + Array(JSONValue.stringArray(sheet["headers"]).prefix(6))
        }
        return ([
            JSONValue.string(call["style"]),
            JSONValue.string(call["design"]),
            JSONValue.string(call["background_style"]),
            JSONValue.string(call["theme"]),
            JSONValue.string(call["title"]),
            JSONValue.string(call["file_name"]),
            JSONValue.string(call["subtitle"]),
            JSONValue.string(call["notes"])
        ] + sheetHints)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct ExcelSheetSpec: Sendable {
    let name: String
    let headers: [String]
    let rows: [[String]]
    let notes: [String]

    static func rows(from value: Any?) -> [[String]] {
        if let rows = value as? [[String]] {
            return rows
        }
        if let rows = value as? [[Any]] {
            return rows.map { $0.map { JSONValue.string($0) } }
        }
        if let dictRows = value as? [[String: Any]] {
            let keys = Array(Set(dictRows.flatMap { $0.keys })).sorted()
            return dictRows.map { row in keys.map { JSONValue.string(row[$0]) } }
        }
        if let array = value as? [Any] {
            return array.map { item in
                if let dict = item as? [String: Any] {
                    return dict.keys.sorted().map { JSONValue.string(dict[$0]) }
                }
                if let row = item as? [Any] {
                    return row.map { JSONValue.string($0) }
                }
                return [JSONValue.string(item)]
            }
        }
        return []
    }
}

private struct PresentationSpec: Sendable {
    let title: String
    let fileName: String?
    let theme: PresentationTheme
    let slides: [SlideSpec]

    init(call: [String: Any]) {
        let resolvedTitle = JSONValue.string(call["title"], fallback: "演示文稿")
        title = resolvedTitle
        fileName = JSONValue.string(call["file_name"]).nilIfEmpty
        theme = PresentationTheme(raw: call["theme"] as? [String: Any], hint: Self.themeHint(from: call))
        let rawSlides = JSONValue.array(call["slides"])
        if rawSlides.isEmpty {
            slides = [
                SlideSpec(layout: "cover", title: resolvedTitle, subtitle: JSONValue.string(call["subtitle"]), bullets: [], table: [], note: nil),
                SlideSpec(layout: "bullets", title: "要点", subtitle: "", bullets: JSONValue.stringArray(call["bullets"]), table: [], note: nil)
            ]
        } else {
            slides = rawSlides.enumerated().map { index, raw in
                SlideSpec(
                    layout: JSONValue.string(raw["layout"], fallback: index == 0 ? "cover" : "bullets"),
                    title: JSONValue.string(raw["title"], fallback: index == 0 ? resolvedTitle : "第 \(index + 1) 页"),
                    subtitle: JSONValue.string(raw["subtitle"]),
                    bullets: JSONValue.stringArray(raw["bullets"] ?? raw["points"] ?? raw["body"]),
                    table: ExcelSheetSpec.rows(from: raw["table"]),
                    note: JSONValue.string(raw["note"]).nilIfEmpty
                )
            }
        }
    }

    var previewText: String {
        slides.enumerated().map { index, slide in
            let bullets = slide.bullets.prefix(5).joined(separator: "；")
            return "\(index + 1). \(slide.title)\(bullets.isEmpty ? "" : "：\(bullets)")"
        }.joined(separator: "\n")
    }

    private static func themeHint(from call: [String: Any]) -> String {
        let slideHints = JSONValue.array(call["slides"]).prefix(4).flatMap { slide in
            [
                JSONValue.string(slide["layout"]),
                JSONValue.string(slide["title"]),
                JSONValue.string(slide["subtitle"]),
                JSONValue.string(slide["note"])
            ] + Array(JSONValue.stringArray(slide["bullets"] ?? slide["points"] ?? slide["body"]).prefix(3))
        }
        return ([
            JSONValue.string(call["style"]),
            JSONValue.string(call["design"]),
            JSONValue.string(call["background_style"]),
            JSONValue.string(call["theme"]),
            JSONValue.string(call["title"]),
            JSONValue.string(call["subtitle"])
        ] + slideHints)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct PresentationTheme: Sendable {
    enum Style: String, Sendable {
        case modern
        case minimal
        case deepBlue
        case tech
        case dark
        case warm
        case green
        case violet
        case editorial
        case luxury
        case playful
    }

    enum Layout: String, Sendable {
        case standard
        case split
        case centered
        case card
        case dashboard
        case poster
        case sidebar
    }

    enum Decoration: String, Sendable {
        case automatic
        case none
        case diagonal
        case circle
        case grid
        case dots
        case frame
        case wave
    }

    let style: Style
    let layout: Layout
    let decoration: Decoration
    let backgroundHex: String
    let background2Hex: String
    let primaryHex: String
    let accentHex: String
    let textHex: String
    let subtleHex: String
    let surfaceHex: String

    init(raw: [String: Any]?, hint: String = "") {
        let styleHint = [
            JSONValue.string(raw?["style"]),
            JSONValue.string(raw?["preset"]),
            JSONValue.string(raw?["background_style"]),
            JSONValue.string(raw?["mood"]),
            hint
        ].filter { !$0.isEmpty }.joined(separator: " ")
        style = Self.style(from: styleHint)
        layout = Self.layout(from: [
            JSONValue.string(raw?["layout"]),
            JSONValue.string(raw?["composition"]),
            JSONValue.string(raw?["template"]),
            styleHint
        ].filter { !$0.isEmpty }.joined(separator: " "))
        decoration = Self.decoration(from: [
            JSONValue.string(raw?["decoration"]),
            JSONValue.string(raw?["ornament"]),
            JSONValue.string(raw?["background_pattern"]),
            styleHint
        ].filter { !$0.isEmpty }.joined(separator: " "), style: style)
        let palette = Self.palette(for: style)
        backgroundHex = Self.hex(raw?["background"], fallback: palette.background)
        background2Hex = Self.hex(raw?["background_2"] ?? raw?["gradient_to"] ?? raw?["secondary_background"], fallback: palette.background2)
        primaryHex = Self.hex(raw?["primary"], fallback: palette.primary)
        accentHex = Self.hex(raw?["accent"], fallback: palette.accent)
        textHex = Self.hex(raw?["text"], fallback: palette.text)
        subtleHex = Self.hex(raw?["subtle"], fallback: palette.subtle)
        surfaceHex = Self.hex(raw?["surface"] ?? raw?["card"] ?? raw?["panel"], fallback: palette.surface)
    }

    private static func hex(_ value: Any?, fallback: String) -> String {
        let raw = JSONValue.string(value, fallback: fallback)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .uppercased()
        if let named = namedColor(raw) {
            return named
        }
        let hexCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard raw.count == 6, raw.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) else { return fallback }
        return raw
    }

    private static func namedColor(_ raw: String) -> String? {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "") {
        case "black", "dark":
            return "111827"
        case "white":
            return "FFFFFF"
        case "navy", "deepblue", "darkblue":
            return "071326"
        case "blue":
            return "2563EB"
        case "cyan", "teal":
            return "22D3EE"
        case "green":
            return "16A34A"
        case "orange":
            return "EA580C"
        case "red":
            return "EF4444"
        case "purple", "violet":
            return "7C3AED"
        case "cream", "beige":
            return "FFF7ED"
        case "gold":
            return "D6A84F"
        case "slate":
            return "334155"
        default:
            return nil
        }
    }

    private static func style(from text: String) -> Style {
        let lower = text.lowercased()
        if lower.contains("深蓝") || lower.contains("navy") || lower.contains("deep blue") || lower.contains("deep_blue") { return .deepBlue }
        if lower.contains("科技") || lower.contains("tech") || lower.contains("ai") || lower.contains("cyber") { return .tech }
        if lower.contains("黑金") || lower.contains("金色") || lower.contains("高级") || lower.contains("奢华") || lower.contains("luxury") || lower.contains("premium") || lower.contains("gold") { return .luxury }
        if lower.contains("暗") || lower.contains("黑") || lower.contains("dark") { return .dark }
        if lower.contains("暖") || lower.contains("橙") || lower.contains("红") || lower.contains("warm") || lower.contains("orange") { return .warm }
        if lower.contains("清爽") || lower.contains("清新") || lower.contains("爽") || lower.contains("fresh") || lower.contains("refreshing") { return .green }
        if lower.contains("绿色") || lower.contains("环保") || lower.contains("生态") || lower.contains("green") { return .green }
        if lower.contains("紫") || lower.contains("violet") || lower.contains("purple") { return .violet }
        if lower.contains("杂志") || lower.contains("editorial") || lower.contains("magazine") || lower.contains("publication") { return .editorial }
        if lower.contains("活泼") || lower.contains("可爱") || lower.contains("playful") || lower.contains("colorful") { return .playful }
        if lower.contains("极简") || lower.contains("简洁") || lower.contains("minimal") || lower.contains("clean") { return .minimal }
        return .modern
    }

    private static func layout(from text: String) -> Layout {
        let lower = text.lowercased()
        if lower.contains("split") || lower.contains("分栏") || lower.contains("左右") || lower.contains("双栏") { return .split }
        if lower.contains("center") || lower.contains("居中") || lower.contains("居中封面") { return .centered }
        if lower.contains("card") || lower.contains("卡片") || lower.contains("玻璃") || lower.contains("面板") { return .card }
        if lower.contains("dashboard") || lower.contains("仪表盘") || lower.contains("数据看板") || lower.contains("网格卡片") { return .dashboard }
        if lower.contains("poster") || lower.contains("海报") || lower.contains("大标题") || lower.contains("封面感") { return .poster }
        if lower.contains("sidebar") || lower.contains("侧栏") || lower.contains("竖栏") { return .sidebar }
        return .standard
    }

    private static func decoration(from text: String, style: Style) -> Decoration {
        let lower = text.lowercased()
        if lower.contains("none") || lower.contains("无装饰") || lower.contains("纯色") { return .none }
        if lower.contains("grid") || lower.contains("网格") || lower.contains("科技线") { return .grid }
        if lower.contains("dot") || lower.contains("点阵") || lower.contains("圆点") { return .dots }
        if lower.contains("circle") || lower.contains("圆形") || lower.contains("圆弧") || lower.contains("泡泡") { return .circle }
        if lower.contains("frame") || lower.contains("边框") || lower.contains("描边") { return .frame }
        if lower.contains("wave") || lower.contains("波浪") || lower.contains("曲线") { return .wave }
        if lower.contains("diagonal") || lower.contains("斜切") || lower.contains("斜线") { return .diagonal }
        switch style {
        case .tech:
            return .grid
        case .minimal:
            return .none
        case .editorial, .luxury:
            return .frame
        case .playful:
            return .circle
        default:
            return .automatic
        }
    }

    private static func palette(for style: Style) -> (background: String, background2: String, primary: String, accent: String, text: String, subtle: String, surface: String) {
        switch style {
        case .modern:
            return ("F7F8FA", "EAF2FF", "111827", "2563EB", "111827", "6B7280", "FFFFFF")
        case .minimal:
            return ("FFFFFF", "FFFFFF", "111827", "111827", "111827", "6B7280", "FFFFFF")
        case .deepBlue:
            return ("071326", "102A6B", "EAF2FF", "3B82F6", "F8FAFC", "B6C6E3", "12213D")
        case .tech:
            return ("08111F", "0F172A", "ECFEFF", "22D3EE", "F8FAFC", "A7F3D0", "101C2D")
        case .dark:
            return ("111827", "030712", "F9FAFB", "60A5FA", "F9FAFB", "D1D5DB", "1F2937")
        case .warm:
            return ("FFF7ED", "FED7AA", "2F241D", "EA580C", "1F2937", "78716C", "FFFFFF")
        case .green:
            return ("F0FDF4", "DCFCE7", "113124", "16A34A", "102A1D", "4B6357", "FFFFFF")
        case .violet:
            return ("F5F3FF", "DDD6FE", "2E1065", "7C3AED", "1F163D", "6D5D8A", "FFFFFF")
        case .editorial:
            return ("FAFAF9", "E7E5E4", "1C1917", "A16207", "1C1917", "78716C", "FFFFFF")
        case .luxury:
            return ("0B0B0D", "1F1B16", "F8F5EC", "D6A84F", "F8F5EC", "D6C6A8", "171717")
        case .playful:
            return ("FFF7FB", "E0F2FE", "1F2937", "EC4899", "1F2937", "6B7280", "FFFFFF")
        }
    }

    var backgroundColor: UIColor { UIColor(hex: backgroundHex) }
    var background2Color: UIColor { UIColor(hex: background2Hex) }
    var primaryColor: UIColor { UIColor(hex: primaryHex) }
    var accentColor: UIColor { UIColor(hex: accentHex) }
    var textColor: UIColor { UIColor(hex: textHex) }
    var subtleColor: UIColor { UIColor(hex: subtleHex) }
    var surfaceColor: UIColor { UIColor(hex: surfaceHex) }
    var isDark: Bool {
        style == .deepBlue || style == .tech || style == .dark || style == .luxury
    }

    var normalizedDraft: [String: Any] {
        [
            "style": style.rawValue,
            "layout": layout.rawValue,
            "decoration": decoration.rawValue,
            "background": backgroundHex,
            "background_2": background2Hex,
            "primary": primaryHex,
            "accent": accentHex,
            "text": textHex,
            "subtle": subtleHex,
            "surface": surfaceHex
        ]
    }
}

private struct SlideSpec: Sendable {
    let layout: String
    let title: String
    let subtitle: String
    let bullets: [String]
    let table: [[String]]
    let note: String?
}

private struct WordSpec: Sendable {
    let title: String
    let fileName: String?
    let subtitle: String
    let theme: DocumentTheme
    let sections: [WordSectionSpec]

    init(call: [String: Any]) {
        title = JSONValue.string(call["title"], fallback: "文档")
        fileName = JSONValue.string(call["file_name"]).nilIfEmpty
        subtitle = JSONValue.string(call["subtitle"])
        theme = DocumentTheme(raw: call["theme"] as? [String: Any], hint: Self.themeHint(from: call))
        let rawSections = JSONValue.array(call["sections"])
        if rawSections.isEmpty {
            let paragraphs = JSONValue.stringArray(call["paragraphs"] ?? call["content"] ?? call["body"])
            let bullets = JSONValue.stringArray(call["bullets"] ?? call["points"])
            sections = [
                WordSectionSpec(
                    heading: JSONValue.string(call["heading"], fallback: paragraphs.isEmpty && bullets.isEmpty ? "概述" : ""),
                    paragraphs: paragraphs.isEmpty && bullets.isEmpty ? ["这是由 Iexa 本地 Office Agent 生成的 Word 文档初稿。"] : paragraphs,
                    bullets: bullets
                )
            ]
        } else {
            sections = rawSections.enumerated().map { index, raw in
                WordSectionSpec(
                    heading: JSONValue.string(raw["heading"] ?? raw["title"], fallback: "第 \(index + 1) 节"),
                    paragraphs: JSONValue.stringArray(raw["paragraphs"] ?? raw["content"] ?? raw["body"]),
                    bullets: JSONValue.stringArray(raw["bullets"] ?? raw["points"])
                )
            }
        }
    }

    var previewText: String {
        sections.map { section in
            let paragraphs = section.paragraphs.prefix(3).joined(separator: " ")
            let bullets = section.bullets.prefix(4).joined(separator: "；")
            return [section.heading, paragraphs, bullets]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "：")
        }.joined(separator: "\n")
    }

    var shouldEmbedPreviewPagesInWord: Bool {
        if theme.isDark { return true }
        if theme.layout != .standard { return true }
        switch theme.style {
        case .editorial, .luxury, .playful, .deepBlue, .tech, .dark:
            return true
        case .modern, .minimal, .warm, .green, .violet:
            return false
        }
    }

    private static func themeHint(from call: [String: Any]) -> String {
        let sectionHints = JSONValue.array(call["sections"]).prefix(4).flatMap { section in
            [
                JSONValue.string(section["heading"] ?? section["title"])
            ] + Array(JSONValue.stringArray(section["paragraphs"] ?? section["content"] ?? section["body"]).prefix(2))
                + Array(JSONValue.stringArray(section["bullets"] ?? section["points"]).prefix(3))
        }
        return ([
            JSONValue.string(call["style"]),
            JSONValue.string(call["design"]),
            JSONValue.string(call["background_style"]),
            JSONValue.string(call["theme"]),
            JSONValue.string(call["title"]),
            JSONValue.string(call["subtitle"])
        ] + sectionHints)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct WordSectionSpec: Sendable {
    let heading: String
    let paragraphs: [String]
    let bullets: [String]
}

private struct DocumentTheme: Sendable {
    let style: PresentationTheme.Style
    let layout: PresentationTheme.Layout
    let decoration: PresentationTheme.Decoration
    let backgroundHex: String
    let background2Hex: String
    let surfaceHex: String
    let accentHex: String
    let titleHex: String
    let textHex: String
    let subtleHex: String

    init(raw: [String: Any]?, hint: String = "") {
        let presentationTheme = PresentationTheme(raw: raw, hint: hint)
        style = presentationTheme.style
        layout = presentationTheme.layout
        decoration = presentationTheme.decoration
        backgroundHex = presentationTheme.backgroundHex
        background2Hex = presentationTheme.background2Hex
        surfaceHex = presentationTheme.surfaceHex
        accentHex = presentationTheme.accentHex
        if presentationTheme.isDark {
            titleHex = presentationTheme.primaryHex
            textHex = presentationTheme.textHex
            subtleHex = presentationTheme.subtleHex
        } else {
            titleHex = presentationTheme.primaryHex
            textHex = presentationTheme.textHex
            subtleHex = presentationTheme.subtleHex
        }
    }

    var backgroundColor: UIColor { UIColor(hex: backgroundHex) }
    var background2Color: UIColor { UIColor(hex: background2Hex) }
    var surfaceColor: UIColor { UIColor(hex: surfaceHex) }
    var accentColor: UIColor { UIColor(hex: accentHex) }
    var titleColor: UIColor { UIColor(hex: titleHex) }
    var textColor: UIColor { UIColor(hex: textHex) }
    var subtleColor: UIColor { UIColor(hex: subtleHex) }
    var isDark: Bool {
        style == .deepBlue || style == .tech || style == .dark || style == .luxury
    }
}

private struct RenderedSlide: Sendable {
    let slide: SlideSpec
    let previewURL: URL
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let scanner = Scanner(string: hex.replacingOccurrences(of: "#", with: ""))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}

private struct ExcelPreviewRenderer {
    static func render(spec: ExcelSpec) -> UIImage {
        let size = CGSize(width: 1200, height: 675)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let theme = spec.theme
            let sheetSurfaceColor = theme.isDark ? UIColor(hex: "FFFFFF") : theme.surfaceColor
            let alternateSurfaceColor = theme.isDark ? UIColor(hex: "F8FAFC") : theme.background2Color
            let bodyTextColor = theme.isDark ? UIColor(hex: "111827") : theme.textColor
            let headerTextColor = theme.isDark ? UIColor(hex: "111827") : theme.accentColor
            let footerTextColor = theme.isDark ? UIColor(hex: "6B7280") : theme.subtleColor
            drawBackground(context.cgContext, size: size, theme: theme)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .bold),
                .foregroundColor: theme.textColor
            ]
            spec.title.draw(in: CGRect(x: 56, y: 38, width: 900, height: 60), withAttributes: titleAttrs)

            guard let sheet = spec.sheets.first else { return }
            let headers = sheet.headers.isEmpty
                ? (sheet.rows.first?.indices.map { "列 \($0 + 1)" } ?? ["内容"])
                : sheet.headers
            let rows = Array(sheet.rows.prefix(8))
            let tableRect = CGRect(x: 56, y: 130, width: 1088, height: 440)
            let tablePath = UIBezierPath(roundedRect: tableRect, cornerRadius: 18)
            context.cgContext.saveGState()
            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 18),
                blur: 34,
                color: UIColor.black.withAlphaComponent(theme.isDark ? 0.34 : 0.10).cgColor
            )
            sheetSurfaceColor.withAlphaComponent(0.98).setFill()
            tablePath.fill()
            context.cgContext.restoreGState()
            theme.accentColor.withAlphaComponent(theme.isDark ? 0.46 : 0.24).setStroke()
            tablePath.lineWidth = theme.style == .luxury ? 2 : 1
            tablePath.stroke()

            let columnCount = max(1, min(headers.count, 6))
            let colWidth = tableRect.width / CGFloat(columnCount)
            let rowHeight: CGFloat = 48
            for rowIndex in 0...(rows.count) {
                let y = tableRect.minY + CGFloat(rowIndex) * rowHeight
                let fill: UIColor
                if rowIndex == 0 {
                    fill = theme.accentColor.withAlphaComponent(theme.isDark ? 0.30 : 0.18)
                } else if rowIndex % 2 == 0 {
                    fill = alternateSurfaceColor.withAlphaComponent(0.92)
                } else {
                    fill = sheetSurfaceColor.withAlphaComponent(0.96)
                }
                fill.setFill()
                UIBezierPath(rect: CGRect(x: tableRect.minX, y: y, width: tableRect.width, height: rowHeight)).fill()
                theme.accentColor.withAlphaComponent(theme.isDark ? 0.20 : 0.10).setStroke()
                UIBezierPath(rect: CGRect(x: tableRect.minX, y: y, width: tableRect.width, height: 1)).stroke()
                for colIndex in 0..<columnCount {
                    let text = rowIndex == 0
                        ? headers[safe: colIndex] ?? ""
                        : rows[safe: rowIndex - 1]?[safe: colIndex] ?? ""
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: rowIndex == 0 ? 22 : 20, weight: rowIndex == 0 ? .semibold : .regular),
                        .foregroundColor: rowIndex == 0
                            ? headerTextColor
                            : bodyTextColor
                    ]
                    text.draw(
                        in: CGRect(x: tableRect.minX + CGFloat(colIndex) * colWidth + 14, y: y + 12, width: colWidth - 22, height: rowHeight - 12),
                        withAttributes: attrs
                    )
                }
            }

            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: footerTextColor
            ]
            "本地 Office Agent · \(spec.sheets.count) 个工作表 · \(sheet.rows.count) 行".draw(
                in: CGRect(x: 56, y: 600, width: 1000, height: 32),
                withAttributes: footerAttrs
            )
        }
    }

    private static func drawBackground(_ context: CGContext, size: CGSize, theme: PresentationTheme) {
        let bounds = CGRect(origin: .zero, size: size)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [theme.backgroundColor.cgColor, theme.background2Color.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        } else {
            theme.backgroundColor.setFill()
            context.fill(bounds)
        }

        switch theme.style {
        case .luxury:
            theme.accentColor.withAlphaComponent(0.80).setFill()
            UIBezierPath(roundedRect: CGRect(x: 56, y: 101, width: 176, height: 6), cornerRadius: 3).fill()
            theme.accentColor.withAlphaComponent(0.18).setStroke()
            let frame = UIBezierPath(roundedRect: bounds.insetBy(dx: 34, dy: 28), cornerRadius: 26)
            frame.lineWidth = 1
            frame.stroke()
        case .tech:
            drawGrid(context, size: size, color: theme.accentColor.withAlphaComponent(0.14), step: 44)
        case .green, .playful:
            theme.accentColor.withAlphaComponent(0.13).setFill()
            UIBezierPath(ovalIn: CGRect(x: 930, y: -90, width: 280, height: 280)).fill()
            theme.primaryColor.withAlphaComponent(0.08).setFill()
            UIBezierPath(ovalIn: CGRect(x: 980, y: 480, width: 160, height: 160)).fill()
        case .editorial:
            theme.accentColor.withAlphaComponent(0.20).setFill()
            UIBezierPath(rect: CGRect(x: 56, y: 118, width: 8, height: 470)).fill()
        default:
            theme.accentColor.withAlphaComponent(theme.isDark ? 0.12 : 0.08).setFill()
            UIBezierPath(ovalIn: CGRect(x: 960, y: -120, width: 320, height: 320)).fill()
        }
    }

    private static func drawGrid(_ context: CGContext, size: CGSize, color: UIColor, step: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        var x: CGFloat = 0
        while x <= size.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.strokePath()
        context.restoreGState()
    }
}

private struct SlidePreviewRenderer {
    static func render(slide: SlideSpec, index: Int, theme: PresentationTheme) -> UIImage {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let isCover = slide.layout.lowercased().contains("cover") || index == 0
            let layout = resolvedLayout(for: slide, theme: theme, isCover: isCover)
            drawBackground(context.cgContext, size: size, theme: theme, index: index, isCover: isCover)
            drawLayoutSurface(context.cgContext, size: size, theme: theme, layout: layout, isCover: isCover)

            if layout == .centered {
                drawCenteredSlide(slide, index: index, theme: theme, isCover: isCover)
                return
            }
            if layout == .poster, isCover {
                drawPosterCover(slide, theme: theme)
                drawPageNumber(index, theme: theme)
                return
            }

            let titleRect = titleFrame(for: layout, isCover: isCover, theme: theme)
            let titleSize = titleFontSize(for: layout, isCover: isCover, theme: theme)
            drawText(slide.title, in: titleRect, font: .systemFont(ofSize: titleSize, weight: .bold), color: theme.textColor)

            if !slide.subtitle.isEmpty {
                drawText(
                    slide.subtitle,
                    in: subtitleFrame(for: layout, titleFrame: titleRect, isCover: isCover),
                    font: .systemFont(ofSize: isCover ? 30 : 22, weight: .medium),
                    color: theme.subtleColor
                )
            }

            if !isCover {
                let body = bodyFrame(for: layout)
                if !slide.table.isEmpty {
                    drawTable(slide.table, origin: body.origin, width: body.width, theme: theme)
                } else if layout == .dashboard {
                    drawBulletCards(slide.bullets, in: body, theme: theme)
                } else if layout == .poster {
                    drawPosterBullets(slide.bullets, in: body, theme: theme)
                } else {
                    drawBullets(slide.bullets, origin: body.origin, width: body.width, theme: theme)
                }
            }

            drawPageNumber(index, theme: theme)
        }
    }

    private static func resolvedLayout(for slide: SlideSpec, theme: PresentationTheme, isCover: Bool) -> PresentationTheme.Layout {
        let lower = slide.layout.lowercased()
        if lower.contains("split") || lower.contains("分栏") { return .split }
        if lower.contains("center") || lower.contains("居中") { return .centered }
        if lower.contains("card") || lower.contains("卡片") { return .card }
        if lower.contains("dashboard") || lower.contains("仪表盘") || lower.contains("grid") { return .dashboard }
        if lower.contains("poster") || lower.contains("海报") { return .poster }
        if lower.contains("sidebar") || lower.contains("侧栏") { return .sidebar }
        if theme.layout != .standard { return theme.layout }
        if isCover && (theme.style == .editorial || theme.style == .luxury) { return .poster }
        return .standard
    }

    private static func titleFrame(
        for layout: PresentationTheme.Layout,
        isCover: Bool,
        theme: PresentationTheme
    ) -> CGRect {
        switch layout {
        case .split:
            return isCover
                ? CGRect(x: 86, y: 166, width: 530, height: 190)
                : CGRect(x: 548, y: 78, width: 560, height: 94)
        case .card:
            return isCover
                ? CGRect(x: 150, y: 170, width: 860, height: 172)
                : CGRect(x: 150, y: 108, width: 870, height: 78)
        case .dashboard:
            return CGRect(x: 82, y: isCover ? 168 : 68, width: 1020, height: isCover ? 168 : 76)
        case .poster:
            return CGRect(x: 92, y: isCover ? 165 : 76, width: 1060, height: isCover ? 220 : 96)
        case .sidebar:
            return CGRect(x: 178, y: isCover ? 180 : 82, width: 900, height: isCover ? 170 : 80)
        case .centered:
            return CGRect(x: 150, y: isCover ? 210 : 88, width: 980, height: isCover ? 160 : 88)
        case .standard:
            let titleX: CGFloat = theme.isDark ? 110 : (theme.style == .minimal ? 82 : 96)
            let titleY: CGFloat = isCover ? (theme.isDark ? 178 : 190) : 78
            return CGRect(x: titleX, y: titleY, width: theme.isDark ? 980 : 940, height: isCover ? 166 : 80)
        }
    }

    private static func subtitleFrame(
        for layout: PresentationTheme.Layout,
        titleFrame: CGRect,
        isCover: Bool
    ) -> CGRect {
        switch layout {
        case .split:
            return isCover
                ? CGRect(x: titleFrame.minX + 4, y: 372, width: titleFrame.width, height: 82)
                : CGRect(x: titleFrame.minX, y: 148, width: titleFrame.width, height: 48)
        case .card:
            return CGRect(x: titleFrame.minX + 2, y: isCover ? 350 : 172, width: titleFrame.width, height: 70)
        case .poster:
            return CGRect(x: titleFrame.minX + 4, y: isCover ? 400 : 150, width: titleFrame.width, height: 72)
        case .sidebar:
            return CGRect(x: titleFrame.minX + 2, y: isCover ? 350 : 146, width: titleFrame.width, height: 64)
        default:
            return CGRect(x: titleFrame.minX + 4, y: isCover ? 348 : 138, width: min(titleFrame.width, 900), height: 70)
        }
    }

    private static func titleFontSize(
        for layout: PresentationTheme.Layout,
        isCover: Bool,
        theme: PresentationTheme
    ) -> CGFloat {
        switch layout {
        case .poster:
            return isCover ? 82 : 50
        case .dashboard:
            return isCover ? 62 : 42
        case .split:
            return isCover ? 58 : 44
        default:
            return isCover ? (theme.isDark ? 68 : 64) : 46
        }
    }

    private static func bodyFrame(for layout: PresentationTheme.Layout) -> CGRect {
        switch layout {
        case .split:
            return CGRect(x: 548, y: 220, width: 560, height: 420)
        case .card:
            return CGRect(x: 150, y: 224, width: 900, height: 400)
        case .dashboard:
            return CGRect(x: 76, y: 172, width: 1090, height: 470)
        case .poster:
            return CGRect(x: 95, y: 238, width: 1040, height: 430)
        case .sidebar:
            return CGRect(x: 180, y: 222, width: 920, height: 410)
        default:
            return CGRect(x: 120, y: 220, width: 920, height: 420)
        }
    }

    private static func drawLayoutSurface(
        _ context: CGContext,
        size: CGSize,
        theme: PresentationTheme,
        layout: PresentationTheme.Layout,
        isCover: Bool
    ) {
        switch layout {
        case .split:
            let panel = CGRect(x: 0, y: 0, width: 465, height: size.height)
            context.saveGState()
            context.setFillColor(theme.surfaceColor.withAlphaComponent(theme.isDark ? 0.10 : 0.74).cgColor)
            context.fill(panel)
            context.restoreGState()
            drawRule(x: 465, y: 0, width: 2, height: size.height, color: theme.accentColor.withAlphaComponent(0.55))
            if !isCover {
                drawRule(x: 548, y: 184, width: 96, height: 5, color: theme.accentColor)
            }
        case .card:
            let rect = CGRect(x: 104, y: 82, width: 1072, height: 555)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 16), blur: 34, color: UIColor.black.withAlphaComponent(theme.isDark ? 0.32 : 0.12).cgColor)
            context.setFillColor(theme.surfaceColor.withAlphaComponent(theme.isDark ? 0.20 : 0.90).cgColor)
            UIBezierPath(roundedRect: rect, cornerRadius: 28).fill()
            context.restoreGState()
            theme.accentColor.withAlphaComponent(0.18).setStroke()
            UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 28).stroke()
        case .dashboard:
            drawRule(x: 76, y: 134, width: 178, height: 5, color: theme.accentColor)
        case .sidebar:
            let rect = CGRect(x: 0, y: 0, width: 130, height: size.height)
            theme.accentColor.withAlphaComponent(theme.isDark ? 0.24 : 0.12).setFill()
            UIBezierPath(rect: rect).fill()
            drawRule(x: 76, y: 82, width: 8, height: 520, color: theme.accentColor)
        case .poster, .centered, .standard:
            break
        }
    }

    private static func drawCenteredSlide(
        _ slide: SlideSpec,
        index: Int,
        theme: PresentationTheme,
        isCover: Bool
    ) {
        let titleRect = CGRect(x: 170, y: isCover ? 220 : 82, width: 940, height: isCover ? 160 : 90)
        drawCenteredText(
            slide.title,
            in: titleRect,
            font: .systemFont(ofSize: isCover ? 66 : 48, weight: .bold),
            color: theme.textColor
        )
        if !slide.subtitle.isEmpty {
            drawCenteredText(
                slide.subtitle,
                in: CGRect(x: 230, y: isCover ? 360 : 150, width: 820, height: 58),
                font: .systemFont(ofSize: isCover ? 28 : 22, weight: .medium),
                color: theme.subtleColor
            )
        }
        if !isCover {
            if !slide.table.isEmpty {
                drawTable(slide.table, origin: CGPoint(x: 180, y: 244), width: 920, theme: theme)
            } else {
                drawBullets(slide.bullets, origin: CGPoint(x: 230, y: 240), width: 820, theme: theme)
            }
        }
        drawPageNumber(index, theme: theme)
    }

    private static func drawPosterCover(_ slide: SlideSpec, theme: PresentationTheme) {
        let titleRect = CGRect(x: 92, y: 150, width: 1080, height: 255)
        drawText(slide.title, in: titleRect, font: .systemFont(ofSize: 82, weight: .heavy), color: theme.textColor)
        if !slide.subtitle.isEmpty {
            drawText(
                slide.subtitle,
                in: CGRect(x: 98, y: 430, width: 850, height: 72),
                font: .systemFont(ofSize: 30, weight: .semibold),
                color: theme.subtleColor
            )
        }
        drawRule(x: 98, y: 525, width: 220, height: 7, color: theme.accentColor)
    }

    private static func drawPageNumber(_ index: Int, theme: PresentationTheme) {
        let pageAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: theme.subtleColor
        ]
        "\(index + 1)".draw(in: CGRect(x: 1120, y: 640, width: 80, height: 30), withAttributes: pageAttrs)
    }

    private static func drawBackground(
        _ context: CGContext,
        size: CGSize,
        theme: PresentationTheme,
        index: Int,
        isCover: Bool
    ) {
        let bounds = CGRect(origin: .zero, size: size)
        switch theme.style {
        case .deepBlue, .tech, .dark, .luxury:
            drawGradient(context, bounds: bounds, startHex: theme.backgroundHex, endHex: theme.background2Hex)
            drawResolvedDecoration(context, size: size, theme: theme)
            if theme.style == .tech {
                drawTopKicker(context, size: size, theme: theme, text: "AI WORKFLOW")
            } else if theme.style == .deepBlue {
                drawTopKicker(context, size: size, theme: theme, text: isCover ? "IEXA DECK" : "SECTION \(index + 1)")
            }
            if theme.style == .luxury {
                drawRule(x: 92, y: 92, width: 150, height: 2, color: theme.accentColor)
                drawRule(x: 92, y: 612, width: 150, height: 2, color: theme.accentColor)
            } else {
                drawRule(x: theme.style == .tech ? 74 : 64, y: theme.style == .tech ? 84 : 72, width: theme.style == .tech ? 118 : 8, height: theme.style == .tech ? 6 : 540, color: theme.accentColor)
            }
        case .minimal:
            UIColor(hex: theme.backgroundHex).setFill()
            context.fill(bounds)
            drawResolvedDecoration(context, size: size, theme: theme)
            drawRule(x: 76, y: 76, width: 1120, height: 2, color: UIColor(hex: theme.textHex).withAlphaComponent(0.16))
            drawRule(x: 76, y: 616, width: 180, height: 4, color: theme.accentColor)
        case .warm, .green, .violet, .editorial, .playful, .modern:
            drawGradient(context, bounds: bounds, startHex: theme.backgroundHex, endHex: theme.background2Hex)
            drawResolvedDecoration(context, size: size, theme: theme)
            let leftRule = theme.style == .editorial ? CGFloat(72) : CGFloat(56)
            drawRule(x: leftRule, y: 52, width: theme.style == .modern ? 9 : 7, height: 560, color: theme.accentColor.withAlphaComponent(theme.style == .editorial ? 0.70 : 1))
        }
    }

    private static func drawResolvedDecoration(_ context: CGContext, size: CGSize, theme: PresentationTheme) {
        let decoration = theme.decoration == .automatic ? automaticDecoration(for: theme.style) : theme.decoration
        switch decoration {
        case .none:
            return
        case .diagonal, .automatic:
            drawDiagonalBand(context, points: [
                CGPoint(x: 900, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 1010, y: size.height)
            ], color: theme.accentColor.withAlphaComponent(theme.isDark ? 0.22 : 0.14))
        case .grid:
            drawGrid(context, size: size, color: theme.accentColor.withAlphaComponent(0.16), step: 44)
            drawDiagonalBand(context, points: [
                CGPoint(x: 860, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: 250), CGPoint(x: 980, y: 350)
            ], color: theme.accentColor.withAlphaComponent(0.24))
        case .circle:
            drawCircle(CGRect(x: 965, y: -72, width: 260, height: 260), color: theme.accentColor.withAlphaComponent(theme.isDark ? 0.20 : 0.16))
            drawCircle(CGRect(x: 1016, y: 482, width: 180, height: 180), color: theme.primaryColor.withAlphaComponent(theme.isDark ? 0.12 : 0.10))
            drawCircle(CGRect(x: 52, y: 548, width: 96, height: 96), color: theme.accentColor.withAlphaComponent(0.12))
        case .dots:
            drawDots(context, size: size, color: theme.accentColor.withAlphaComponent(0.20), step: 36)
        case .frame:
            let frame = CGRect(x: 48, y: 48, width: size.width - 96, height: size.height - 96)
            context.saveGState()
            context.setStrokeColor(theme.accentColor.withAlphaComponent(theme.isDark ? 0.45 : 0.34).cgColor)
            context.setLineWidth(2)
            context.stroke(frame)
            context.restoreGState()
        case .wave:
            drawWave(context, size: size, color: theme.accentColor.withAlphaComponent(theme.isDark ? 0.18 : 0.14))
        }
    }

    private static func automaticDecoration(for style: PresentationTheme.Style) -> PresentationTheme.Decoration {
        switch style {
        case .tech:
            return .grid
        case .minimal:
            return .none
        case .editorial, .luxury:
            return .frame
        case .playful:
            return .circle
        case .warm, .green, .violet, .modern, .deepBlue, .dark:
            return .diagonal
        }
    }

    private static func drawCircle(_ rect: CGRect, color: UIColor) {
        color.setFill()
        UIBezierPath(ovalIn: rect).fill()
    }

    private static func drawDots(_ context: CGContext, size: CGSize, color: UIColor, step: CGFloat) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        var y: CGFloat = 96
        while y <= size.height - 90 {
            var x: CGFloat = 820
            while x <= size.width - 70 {
                context.fillEllipse(in: CGRect(x: x, y: y, width: 4, height: 4))
                x += step
            }
            y += step
        }
        context.restoreGState()
    }

    private static func drawWave(_ context: CGContext, size: CGSize, color: UIColor) {
        context.saveGState()
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: size.height * 0.76))
        context.addCurve(
            to: CGPoint(x: size.width, y: size.height * 0.66),
            control1: CGPoint(x: size.width * 0.32, y: size.height * 0.56),
            control2: CGPoint(x: size.width * 0.62, y: size.height * 0.88)
        )
        context.addLine(to: CGPoint(x: size.width, y: size.height))
        context.addLine(to: CGPoint(x: 0, y: size.height))
        context.closePath()
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }
    private static func drawGradient(_ context: CGContext, bounds: CGRect, startHex: String, endHex: String) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [UIColor(hex: startHex).cgColor, UIColor(hex: endHex).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
            UIColor(hex: startHex).setFill()
            context.fill(bounds)
            return
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.minX, y: bounds.minY),
            end: CGPoint(x: bounds.maxX, y: bounds.maxY),
            options: []
        )
    }

    private static func drawGrid(_ context: CGContext, size: CGSize, color: UIColor, step: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        var x: CGFloat = 0
        while x <= size.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = 0
        while y <= size.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawDiagonalBand(_ context: CGContext, points: [CGPoint], color: UIColor) {
        guard let first = points.first else { return }
        context.saveGState()
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.closePath()
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawRule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: UIColor) {
        color.setFill()
        UIBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: height / 2).fill()
    }

    private static func drawTopKicker(_ context: CGContext, size: CGSize, theme: PresentationTheme, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: theme.subtleColor
        ]
        text.draw(in: CGRect(x: 110, y: 86, width: 320, height: 24), withAttributes: attrs)
    }

    private static func drawBullets(_ bullets: [String], origin: CGPoint, width: CGFloat, theme: PresentationTheme) {
        for (index, bullet) in bullets.prefix(6).enumerated() {
            let y = origin.y + CGFloat(index) * 70
            theme.accentColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: origin.x, y: y + 10, width: 16, height: 16)).fill()
            drawText(
                bullet,
                in: CGRect(x: origin.x + 34, y: y, width: width - 34, height: 54),
                font: .systemFont(ofSize: 30, weight: .semibold),
                color: theme.textColor
            )
        }
    }

    private static func drawBulletCards(_ bullets: [String], in rect: CGRect, theme: PresentationTheme) {
        let items = Array((bullets.isEmpty ? ["核心要点", "执行路径", "预期结果", "下一步"] : bullets).prefix(6))
        let columns = items.count <= 3 ? 3 : 2
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let gap: CGFloat = 22
        let cardWidth = (rect.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cardHeight = min(CGFloat(132), (rect.height - gap * CGFloat(max(0, rows - 1))) / CGFloat(max(1, rows)))

        for (index, item) in items.enumerated() {
            let col = index % columns
            let row = index / columns
            let card = CGRect(
                x: rect.minX + CGFloat(col) * (cardWidth + gap),
                y: rect.minY + CGFloat(row) * (cardHeight + gap),
                width: cardWidth,
                height: cardHeight
            )
            let fill = theme.surfaceColor.withAlphaComponent(theme.isDark ? 0.16 : 0.82)
            fill.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 18).fill()
            theme.accentColor.withAlphaComponent(theme.isDark ? 0.34 : 0.22).setStroke()
            UIBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), cornerRadius: 18).stroke()
            drawRule(x: card.minX + 24, y: card.minY + 22, width: 34, height: 6, color: theme.accentColor)
            drawText(
                item,
                in: CGRect(x: card.minX + 24, y: card.minY + 44, width: card.width - 48, height: card.height - 54),
                font: .systemFont(ofSize: 25, weight: .semibold),
                color: theme.textColor
            )
        }
    }

    private static func drawPosterBullets(_ bullets: [String], in rect: CGRect, theme: PresentationTheme) {
        let items = Array(bullets.prefix(5))
        for (index, item) in items.enumerated() {
            let y = rect.minY + CGFloat(index) * 78
            let number = String(format: "%02d", index + 1)
            drawText(
                number,
                in: CGRect(x: rect.minX, y: y - 4, width: 74, height: 42),
                font: .monospacedDigitSystemFont(ofSize: 25, weight: .bold),
                color: theme.accentColor
            )
            drawText(
                item,
                in: CGRect(x: rect.minX + 88, y: y, width: rect.width - 120, height: 58),
                font: .systemFont(ofSize: 31, weight: .semibold),
                color: theme.textColor
            )
            drawRule(x: rect.minX + 88, y: y + 60, width: min(760, rect.width - 120), height: 1, color: theme.subtleColor.withAlphaComponent(0.25))
        }
    }

    private static func drawTable(_ table: [[String]], origin: CGPoint, width: CGFloat, theme: PresentationTheme) {
        let rows = Array(table.prefix(6))
        let columns = max(1, min(rows.map(\.count).max() ?? 1, 5))
        let colWidth = width / CGFloat(columns)
        let rowHeight: CGFloat = 58
        let dark = theme.isDark
        for rowIndex in 0..<rows.count {
            let y = origin.y + CGFloat(rowIndex) * rowHeight
            let fill = rowIndex == 0
                ? theme.accentColor.withAlphaComponent(dark ? 0.28 : 0.14)
                : (dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.white.withAlphaComponent(0.62))
            fill.setFill()
            UIBezierPath(roundedRect: CGRect(x: origin.x, y: y, width: width, height: rowHeight - 6), cornerRadius: 8).fill()
            for colIndex in 0..<columns {
                let text = rows[rowIndex][safe: colIndex] ?? ""
                drawText(
                    text,
                    in: CGRect(x: origin.x + CGFloat(colIndex) * colWidth + 14, y: y + 12, width: colWidth - 22, height: rowHeight - 12),
                    font: .systemFont(ofSize: rowIndex == 0 ? 22 : 20, weight: rowIndex == 0 ? .bold : .medium),
                    color: rowIndex == 0 ? theme.accentColor : theme.textColor
                )
            }
        }
    }

    private static func drawCenteredText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 5
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
        )
    }

    private static func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 4
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
        )
    }
}

private struct WordPreviewRenderer {
    private enum BlockStyle {
        case title
        case subtitle
        case heading
        case paragraph
        case bullet
    }

    private struct TextBlock {
        let text: String
        let style: BlockStyle
    }

    private static let pageSize = CGSize(width: 1000, height: 1414)
    private static let pageInsets = UIEdgeInsets(top: 106, left: 116, bottom: 118, right: 116)

    static func render(spec: WordSpec) -> UIImage {
        renderPages(spec: spec).first ?? blankPage(spec: spec)
    }

    static func renderPages(spec: WordSpec) -> [UIImage] {
        let blocks = makeBlocks(spec: spec)
        let pages = paginate(blocks: blocks, theme: spec.theme)
        guard !pages.isEmpty else { return [blankPage(spec: spec)] }
        return pages.enumerated().map { index, page in
            renderPage(blocks: page, spec: spec, pageNumber: index + 1, pageCount: pages.count)
        }
    }

    private static func makeBlocks(spec: WordSpec) -> [TextBlock] {
        var blocks: [TextBlock] = [TextBlock(text: spec.title, style: .title)]
        if !spec.subtitle.isEmpty {
            blocks.append(TextBlock(text: spec.subtitle, style: .subtitle))
        }
        for section in spec.sections {
            if !section.heading.isEmpty {
                blocks.append(TextBlock(text: section.heading, style: .heading))
            }
            for paragraph in section.paragraphs {
                blocks.append(TextBlock(text: paragraph, style: .paragraph))
            }
            for bullet in section.bullets {
                blocks.append(TextBlock(text: bullet, style: .bullet))
            }
        }
        return blocks
    }

    private static func paginate(blocks: [TextBlock], theme: DocumentTheme) -> [[TextBlock]] {
        let contentWidth = pageSize.width - pageInsets.left - pageInsets.right
        let maxY = pageSize.height - pageInsets.bottom
        var pages: [[TextBlock]] = []
        var current: [TextBlock] = []
        var y = pageInsets.top

        for block in blocks {
            let width = block.style == .bullet ? contentWidth - 34 : contentWidth
            let blockHeight = height(for: block, width: width, theme: theme)
            let spacing = spacingAfter(block.style)
            if y + blockHeight > maxY, !current.isEmpty {
                pages.append(current)
                current = []
                y = pageInsets.top
            }
            current.append(block)
            y += blockHeight + spacing
        }

        if !current.isEmpty {
            pages.append(current)
        }
        return pages
    }

    private static func renderPage(
        blocks: [TextBlock],
        spec: WordSpec,
        pageNumber: Int,
        pageCount: Int
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: pageSize)
        return renderer.image { context in
            drawDocumentBackground(context.cgContext, theme: spec.theme)

            let contentRect = CGRect(
                x: pageInsets.left,
                y: pageInsets.top,
                width: pageSize.width - pageInsets.left - pageInsets.right,
                height: pageSize.height - pageInsets.top - pageInsets.bottom
            )

            var y = contentRect.minY
            for block in blocks {
                let width = block.style == .bullet ? contentRect.width - 34 : contentRect.width
                let height = height(for: block, width: width, theme: spec.theme)
                switch block.style {
                case .bullet:
                    drawBullet(
                        block.text,
                        in: CGRect(x: contentRect.minX, y: y, width: contentRect.width, height: height),
                        theme: spec.theme
                    )
                default:
                    drawText(
                        block.text,
                        in: CGRect(x: contentRect.minX, y: y, width: width, height: height),
                        style: block.style,
                        theme: spec.theme
                    )
                }
                y += height + spacingAfter(block.style)
            }

            let footer = pageCount > 1 ? "\(pageNumber) / \(pageCount)" : "\(pageNumber)"
            footer.draw(
                in: CGRect(x: pageInsets.left, y: pageSize.height - 74, width: 160, height: 26),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: spec.theme.subtleColor
                ]
            )
        }
    }

    private static func drawDocumentBackground(_ context: CGContext, theme: DocumentTheme) {
        let bounds = CGRect(origin: .zero, size: pageSize)
        if theme.isDark {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [theme.backgroundColor.cgColor, theme.background2Color.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.minX, y: bounds.minY),
                    end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                    options: []
                )
            } else {
                theme.backgroundColor.setFill()
                context.fill(bounds)
            }
            theme.accentColor.withAlphaComponent(0.78).setFill()
            UIBezierPath(roundedRect: CGRect(x: pageInsets.left, y: pageInsets.top - 36, width: 132, height: 7), cornerRadius: 3.5).fill()
            theme.accentColor.withAlphaComponent(0.34).setStroke()
            UIBezierPath(rect: bounds.insetBy(dx: 54, dy: 54)).stroke()
        } else {
            UIColor.white.setFill()
            context.fill(bounds)
            if theme.style != .minimal {
                theme.accentColor.withAlphaComponent(0.08).setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: pageSize.height - 250, width: pageSize.width, height: 250), cornerRadius: 0).fill()
            }
        }
    }

    private static func blankPage(spec: WordSpec) -> UIImage {
        renderPage(blocks: [TextBlock(text: spec.title, style: .title)], spec: spec, pageNumber: 1, pageCount: 1)
    }

    private static func height(for block: TextBlock, width: CGFloat, theme: DocumentTheme) -> CGFloat {
        let rect = (block.text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(for: block.style, theme: theme),
            context: nil
        )
        return max(ceil(rect.height), minimumHeight(for: block.style))
    }

    private static func drawText(_ text: String, in rect: CGRect, style: BlockStyle, theme: DocumentTheme) {
        (text as NSString).draw(
            in: rect,
            withAttributes: attributes(for: style, theme: theme)
        )
    }

    private static func drawBullet(_ text: String, in rect: CGRect, theme: DocumentTheme) {
        let bulletRect = CGRect(x: rect.minX + 8, y: rect.minY + 12, width: 8, height: 8)
        theme.accentColor.setFill()
        UIBezierPath(ovalIn: bulletRect).fill()
        drawText(
            text,
            in: CGRect(x: rect.minX + 34, y: rect.minY, width: rect.width - 34, height: rect.height),
            style: .bullet,
            theme: theme
        )
    }

    private static func attributes(for style: BlockStyle, theme: DocumentTheme) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = style == .paragraph || style == .bullet ? 7 : 4
        switch style {
        case .title:
            return [.font: UIFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: theme.titleColor, .paragraphStyle: paragraph]
        case .subtitle:
            return [.font: UIFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: theme.subtleColor, .paragraphStyle: paragraph]
        case .heading:
            return [.font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: theme.titleColor, .paragraphStyle: paragraph]
        case .paragraph:
            return [.font: UIFont.systemFont(ofSize: 23, weight: .regular), .foregroundColor: theme.textColor, .paragraphStyle: paragraph]
        case .bullet:
            return [.font: UIFont.systemFont(ofSize: 22, weight: .regular), .foregroundColor: theme.textColor, .paragraphStyle: paragraph]
        }
    }

    private static func minimumHeight(for style: BlockStyle) -> CGFloat {
        switch style {
        case .title:
            return 58
        case .subtitle:
            return 36
        case .heading:
            return 42
        case .paragraph:
            return 34
        case .bullet:
            return 32
        }
    }

    private static func spacingAfter(_ style: BlockStyle) -> CGFloat {
        switch style {
        case .title:
            return 22
        case .subtitle:
            return 28
        case .heading:
            return 16
        case .paragraph:
            return 18
        case .bullet:
            return 8
        }
    }
}

private struct PDFRenderPlan {
    let title: String
    let previewText: String
    let pages: [UIImage]

    init(title: String, previewText: String, pages: [UIImage]) {
        self.title = title
        self.previewText = previewText
        self.pages = pages
    }

    init(call: [String: Any]) {
        let mode = [
            JSONValue.string(call["format"]),
            JSONValue.string(call["mode"]),
            JSONValue.string(call["source_type"]),
            JSONValue.string(call["document_type"])
        ].joined(separator: " ").lowercased()

        if !JSONValue.array(call["slides"]).isEmpty
            || mode.contains("ppt")
            || mode.contains("slide")
            || mode.contains("演示") {
            let spec = PresentationSpec(call: call)
            title = spec.title
            previewText = spec.previewText
            pages = spec.slides.enumerated().map { index, slide in
                SlidePreviewRenderer.render(slide: slide, index: index, theme: spec.theme)
            }
        } else if !JSONValue.array(call["sheets"]).isEmpty
            || call["rows"] != nil
            || call["headers"] != nil
            || mode.contains("excel")
            || mode.contains("sheet")
            || mode.contains("table")
            || mode.contains("表格") {
            let spec = ExcelSpec(call: call)
            title = spec.title
            previewText = spec.previewText
            pages = [ExcelPreviewRenderer.render(spec: spec)]
        } else {
            let spec = WordSpec(call: call)
            title = spec.title
            previewText = spec.previewText
            pages = WordPreviewRenderer.renderPages(spec: spec)
        }
    }
}

private struct PDFDocumentRenderer {
    static func write(images: [UIImage], title: String, to url: URL) throws {
        guard let first = images.first else {
            throw OfficeDocumentError.renderFailed
        }
        let bounds = CGRect(origin: .zero, size: first.size)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Iexa",
            kCGPDFContextTitle as String: title
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let data = renderer.pdfData { context in
            for image in images {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(bounds)
                image.draw(in: bounds)
            }
        }
        try data.write(to: url, options: .atomic)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct ExcelOpenXMLBuilder {
    let spec: ExcelSpec

    func build() throws -> [OfficeZipEntry] {
        var entries: [OfficeZipEntry] = []
        entries.append(.text("[Content_Types].xml", contentTypes))
        entries.append(.text("_rels/.rels", packageRelationships))
        entries.append(.text("xl/workbook.xml", workbookXML))
        entries.append(.text("xl/_rels/workbook.xml.rels", workbookRelationships))
        entries.append(.text("xl/styles.xml", stylesXML))
        for (index, sheet) in spec.sheets.enumerated() {
            entries.append(.text("xl/worksheets/sheet\(index + 1).xml", worksheetXML(sheet: sheet)))
        }
        return entries
    }

    private var contentTypes: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        \(spec.sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined(separator: "\n"))
        </Types>
        """
    }

    private var packageRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }

    private var workbookXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        \(spec.sheets.enumerated().map { index, sheet in "<sheet name=\"\(xmlEscape(validSheetName(sheet.name)))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>" }.joined(separator: "\n"))
        </sheets>
        </workbook>
        """
    }

    private var workbookRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(spec.sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined(separator: "\n"))
        <Relationship Id="rId\(spec.sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private var stylesXML: String {
        let theme = spec.theme
        let bodyTextHex = theme.isDark ? "111827" : theme.textHex
        let headerTextHex = Self.readableTextHex(on: theme.accentHex)
        let bodyFillHex = theme.isDark ? "FFFFFF" : theme.surfaceHex
        let alternateFillHex = theme.isDark ? "F8FAFC" : theme.background2Hex
        let borderHex = theme.isDark ? "CBD5E1" : theme.background2Hex
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="3">
        <font><sz val="11"/><color rgb="FF\(bodyTextHex)"/><name val="Arial"/><family val="2"/></font>
        <font><b/><sz val="11"/><color rgb="FF\(headerTextHex)"/><name val="Arial"/><family val="2"/></font>
        <font><b/><sz val="11"/><color rgb="FF\(theme.accentHex)"/><name val="Arial"/><family val="2"/></font>
        </fonts>
        <fills count="5">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF\(theme.accentHex)"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF\(bodyFillHex)"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF\(alternateFillHex)"/><bgColor indexed="64"/></patternFill></fill>
        </fills>
        <borders count="2">
        <border><left/><right/><top/><bottom/><diagonal/></border>
        <border><left style="thin"><color rgb="FF\(borderHex)"/></left><right style="thin"><color rgb="FF\(borderHex)"/></right><top style="thin"><color rgb="FF\(borderHex)"/></top><bottom style="thin"><color rgb="FF\(borderHex)"/></bottom><diagonal/></border>
        </borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="4">
        <xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
        <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>
        <xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
        <xf numFmtId="0" fontId="2" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        <tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/>
        </styleSheet>
        """
    }

    private static func readableTextHex(on backgroundHex: String) -> String {
        let cleaned = backgroundHex.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = Int(cleaned, radix: 16) else {
            return "111827"
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.55 ? "111827" : "FFFFFF"
    }

    private func worksheetXML(sheet: ExcelSheetSpec) -> String {
        let headers = sheet.headers
        var rows: [[String]] = []
        if !headers.isEmpty { rows.append(headers) }
        rows.append(contentsOf: sheet.rows)
        if rows.isEmpty {
            rows = [[sheet.name]]
        }
        let rowColumnCount = rows.map(\.count).max() ?? 0
        let columnCount = max(1, max(headers.count, rowColumnCount))
        let effectiveRowCount = max(rows.count, headers.isEmpty ? 1 : 12)
        let lastCellRef = "\(columnName(columnCount - 1))\(effectiveRowCount)"
        let columnsXML = (0..<columnCount).map { index in
            let width = index == 0 ? 16 : 18
            return #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(width)" customWidth="1"/>"#
        }.joined(separator: "\n")
        let freezeHeaderXML = headers.isEmpty ? "" : #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        let autoFilterXML = headers.isEmpty ? "" : #"<autoFilter ref="A1:\#(columnName(columnCount - 1))\#(effectiveRowCount)"/>"#
        let rowXML = (0..<effectiveRowCount).map { rowIndex in
            let row = rows[safe: rowIndex] ?? []
            let number = rowIndex + 1
            let rowStyle = rowIndex == 0 && !headers.isEmpty ? 1 : (rowIndex % 2 == 0 ? 2 : 0)
            let rowHeight = rowIndex == 0 && !headers.isEmpty ? 26 : 24
            let cells = (0..<columnCount).map { columnIndex in
                let value = row[safe: columnIndex] ?? ""
                let ref = "\(columnName(columnIndex))\(number)"
                let style = #" s="\#(rowStyle)""#
                return "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
            }.joined()
            return #"<row r="\#(number)" ht="\#(rowHeight)" customHeight="1">\#(cells)</row>"#
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <dimension ref="A1:\(lastCellRef)"/>
        <sheetPr><tabColor rgb="FF\(spec.theme.accentHex)"/></sheetPr>
        \(freezeHeaderXML)
        <sheetFormatPr defaultRowHeight="24"/>
        <cols>
        \(columnsXML)
        </cols>
        <sheetData>
        \(rowXML)
        </sheetData>
        \(autoFilterXML)
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
        </worksheet>
        """
    }

    private func validSheetName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Sheet" : cleaned).prefix(31))
    }
}

private struct WordOpenXMLBuilder {
    let spec: WordSpec
    let visualPageURLs: [URL]

    func build() throws -> [OfficeZipEntry] {
        var entries: [OfficeZipEntry] = [
            .text("[Content_Types].xml", contentTypes),
            .text("_rels/.rels", packageRelationships),
            .text("docProps/core.xml", corePropertiesXML),
            .text("docProps/app.xml", appPropertiesXML),
            .text("word/document.xml", documentXML),
            .text("word/_rels/document.xml.rels", documentRelationships),
            .text("word/styles.xml", stylesXML),
            .text("word/settings.xml", settingsXML),
            .text("word/fontTable.xml", fontTableXML)
        ]
        for (index, url) in visualPageURLs.enumerated() {
            let data = try Data(contentsOf: url)
            entries.append(OfficeZipEntry(path: "word/media/page\(index + 1).png", data: data))
        }
        return entries
    }

    private var contentTypes: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(visualPageURLs.isEmpty ? "" : #"<Default Extension="png" ContentType="image/png"/>"#)
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
        <Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/>
        </Types>
        """
    }

    private var packageRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private var documentRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable" Target="fontTable.xml"/>
        \(visualPageURLs.indices.map { "<Relationship Id=\"rId\($0 + 4)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/page\($0 + 1).png\"/>" }.joined(separator: "\n"))
        </Relationships>
        """
    }

    private var documentXML: String {
        if !visualPageURLs.isEmpty {
            return visualDocumentXML
        }
        let paragraphs = documentParagraphs.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \(documentBackgroundXML)
        <w:body>
        \(paragraphs)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/><w:cols w:space="708"/><w:docGrid w:linePitch="360"/></w:sectPr>
        </w:body>
        </w:document>
        """
    }

    private var visualDocumentXML: String {
        let pages = visualPageURLs.indices.map { index in
            visualPageParagraph(index: index)
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>
        \(pages)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/><w:cols w:space="0"/><w:docGrid w:linePitch="360"/></w:sectPr>
        </w:body>
        </w:document>
        """
    }

    private func visualPageParagraph(index: Int) -> String {
        let relationshipId = "rId\(index + 4)"
        let pageBreak = index < visualPageURLs.count - 1 ? #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"# : ""
        return """
        <w:p>
        <w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>
        <w:r>
        <w:drawing>
        <wp:inline distT="0" distB="0" distL="0" distR="0">
        <wp:extent cx="7560000" cy="10689840"/>
        <wp:effectExtent l="0" t="0" r="0" b="0"/>
        <wp:docPr id="\(index + 1)" name="Word visual page \(index + 1)" descr="\(xmlEscape(spec.title)) page \(index + 1)"/>
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
        <a:graphic>
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <pic:pic>
        <pic:nvPicPr><pic:cNvPr id="\(index + 1)" name="page-\(index + 1).png"/><pic:cNvPicPr/></pic:nvPicPr>
        <pic:blipFill><a:blip r:embed="\(relationshipId)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="7560000" cy="10689840"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
        </pic:pic>
        </a:graphicData>
        </a:graphic>
        </wp:inline>
        </w:drawing>
        </w:r>
        </w:p>
        \(pageBreak)
        """
    }

    private var documentBackgroundXML: String {
        guard spec.theme.isDark else { return "" }
        return #"<w:background w:color="\#(spec.theme.backgroundHex)"/>"#
    }

    private var documentParagraphs: [String] {
        var items: [String] = [
            paragraph(spec.title, style: "Title")
        ]
        if !spec.subtitle.isEmpty {
            items.append(paragraph(spec.subtitle, style: "Subtitle"))
        }
        for section in spec.sections {
            if !section.heading.isEmpty {
                items.append(paragraph(section.heading, style: "Heading1"))
            }
            for text in section.paragraphs {
                items.append(paragraph(text, style: "Normal"))
            }
            for bullet in section.bullets {
                items.append(paragraph("• \(bullet)", style: "ListParagraph"))
            }
        }
        return items
    }

    private func paragraph(_ text: String, style: String) -> String {
        """
        <w:p><w:pPr><w:pStyle w:val="\(style)"/>\(paragraphShadingXML)</w:pPr><w:r><w:t>\(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private var paragraphShadingXML: String {
        guard spec.theme.isDark else { return "" }
        return #"<w:shd w:val="clear" w:color="auto" w:fill="\#(spec.theme.backgroundHex)"/>"#
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Aptos" w:eastAsia="PingFang SC" w:hAnsi="Aptos"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:color w:val="\(spec.theme.textHex)"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/>\(paragraphShadingXML)</w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="280"/></w:pPr><w:rPr><w:b/><w:sz w:val="52"/><w:szCs w:val="52"/><w:color w:val="\(spec.theme.titleHex)"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="28"/><w:szCs w:val="28"/><w:color w:val="\(spec.theme.subtleHex)"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:before="360" w:after="160"/></w:pPr><w:rPr><w:b/><w:sz w:val="34"/><w:szCs w:val="34"/><w:color w:val="\(spec.theme.titleHex)"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="420"/></w:pPr></w:style>
        </w:styles>
        """
    }

    private var settingsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:zoom w:percent="100"/><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/></w:settings>
        """
    }

    private var fontTableXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:fonts xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:font w:name="Aptos"><w:family w:val="swiss"/></w:font>
        <w:font w:name="PingFang SC"><w:family w:val="swiss"/></w:font>
        </w:fonts>
        """
    }

    private var corePropertiesXML: String {
        let title = xmlEscape(spec.title)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(title)</dc:title><dc:creator>Iexa</dc:creator><cp:lastModifiedBy>Iexa</cp:lastModifiedBy><cp:revision>1</cp:revision>
        <dcterms:created xsi:type="dcterms:W3CDTF">2026-06-04T00:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-06-04T00:00:00Z</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private var appPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <Application>Iexa</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop><Company></Company><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>16.0000</AppVersion>
        </Properties>
        """
    }
}

private struct PowerPointOpenXMLBuilder {
    let spec: PresentationSpec
    let renderedSlides: [RenderedSlide]

    func build() throws -> [OfficeZipEntry] {
        var entries: [OfficeZipEntry] = []
        entries.append(.text("[Content_Types].xml", contentTypes))
        entries.append(.text("_rels/.rels", packageRelationships))
        entries.append(.text("docProps/core.xml", corePropertiesXML))
        entries.append(.text("docProps/app.xml", appPropertiesXML))
        entries.append(.text("ppt/presentation.xml", presentationXML))
        entries.append(.text("ppt/_rels/presentation.xml.rels", presentationRelationships))
        entries.append(.text("ppt/presProps.xml", presentationPropertiesXML))
        entries.append(.text("ppt/viewProps.xml", viewPropertiesXML))
        entries.append(.text("ppt/tableStyles.xml", tableStylesXML))
        entries.append(.text("ppt/theme/theme1.xml", themeXML))
        entries.append(.text("ppt/slideMasters/slideMaster1.xml", slideMasterXML))
        entries.append(.text("ppt/slideMasters/_rels/slideMaster1.xml.rels", slideMasterRelationships))
        entries.append(.text("ppt/slideLayouts/slideLayout1.xml", slideLayoutXML))
        entries.append(.text("ppt/slideLayouts/_rels/slideLayout1.xml.rels", slideLayoutRelationships))
        for (index, rendered) in renderedSlides.enumerated() {
            entries.append(.text("ppt/slides/slide\(index + 1).xml", slideXML(index: index)))
            entries.append(.text("ppt/slides/_rels/slide\(index + 1).xml.rels", slideRelationships(index: index)))
            let data = try Data(contentsOf: rendered.previewURL)
            entries.append(OfficeZipEntry(path: "ppt/media/image\(index + 1).png", data: data))
        }
        return entries
    }

    private var contentTypes: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>
        <Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>
        <Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        \(renderedSlides.indices.map { "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined(separator: "\n"))
        </Types>
        """
    }

    private var packageRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private var presentationXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" saveSubsetFonts="1" autoCompressPictures="0">
        <p:sldMasterIdLst>
        <p:sldMasterId id="2147483648" r:id="rId1"/>
        </p:sldMasterIdLst>
        <p:sldIdLst>
        \(renderedSlides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 6)\"/>" }.joined(separator: "\n"))
        </p:sldIdLst>
        <p:sldSz cx="12192000" cy="6858000" type="screen16x9"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        <p:defaultTextStyle>
        <a:defPPr><a:defRPr lang="zh-CN"/></a:defPPr>
        <a:lvl1pPr marL="0" algn="l" defTabSz="457200" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr>
        </p:defaultTextStyle>
        </p:presentation>
        """
    }

    private var presentationRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps" Target="presProps.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps" Target="viewProps.xml"/>
        <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles" Target="tableStyles.xml"/>
        \(renderedSlides.indices.map { "<Relationship Id=\"rId\($0 + 6)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined(separator: "\n"))
        </Relationships>
        """
    }

    private var themeXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Iexa Office Agent">
        <a:themeElements>
        <a:clrScheme name="Iexa">
        <a:dk1><a:srgbClr val="\(spec.theme.textHex)"/></a:dk1>
        <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="111827"/></a:dk2>
        <a:lt2><a:srgbClr val="\(spec.theme.backgroundHex)"/></a:lt2>
        <a:accent1><a:srgbClr val="\(spec.theme.accentHex)"/></a:accent1>
        <a:accent2><a:srgbClr val="14B8A6"/></a:accent2>
        <a:accent3><a:srgbClr val="22C55E"/></a:accent3>
        <a:accent4><a:srgbClr val="F59E0B"/></a:accent4>
        <a:accent5><a:srgbClr val="A855F7"/></a:accent5>
        <a:accent6><a:srgbClr val="EF4444"/></a:accent6>
        <a:hlink><a:srgbClr val="2563EB"/></a:hlink>
        <a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Iexa">
        <a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface="PingFang SC"/><a:cs typeface="Arial"/></a:majorFont>
        <a:minorFont><a:latin typeface="Aptos"/><a:ea typeface="PingFang SC"/><a:cs typeface="Arial"/></a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="Iexa">
        <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"/></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:lumMod val="80000"/><a:lumOff val="20000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill>
        <a:solidFill><a:schemeClr val="phClr"><a:lumMod val="90000"/></a:schemeClr></a:solidFill>
        </a:fillStyleLst>
        <a:lnStyleLst>
        <a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        </a:lnStyleLst>
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
        <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
        </a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }

    private var slideMasterXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        <p:txStyles>
        <p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/></a:defRPr></a:lvl1pPr></p:titleStyle>
        <p:bodyStyle><a:lvl1pPr marL="342900" indent="-342900"><a:defRPr sz="2800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/></a:defRPr></a:lvl1pPr></p:bodyStyle>
        <p:otherStyle><a:lvl1pPr><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/></a:defRPr></a:lvl1pPr></p:otherStyle>
        </p:txStyles>
        </p:sldMaster>
        """
    }

    private var slideMasterRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
    }

    private var slideLayoutXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" type="blank" preserve="1">
        <p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
    }

    private var slideLayoutRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
    }

    private var presentationPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentationPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:extLst><p:ext uri="{E76CE94A-603C-4142-B9EB-6D1370010A27}"><p14:discardImageEditData xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" val="0"/></p:ext><p:ext uri="{D31A062A-798A-4329-ABDD-BBA856620510}"><p14:defaultImageDpi xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" val="0"/></p:ext></p:extLst>
        </p:presentationPr>
        """
    }

    private var viewPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:viewPr xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" lastView="sldThumbnailView">
        <p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr>
        <p:slideViewPr><p:cSldViewPr snapToGrid="0" snapToObjects="1"><p:cViewPr varScale="1"><p:scale><a:sx n="100" d="100"/><a:sy n="100" d="100"/></p:scale><p:origin x="0" y="0"/></p:cViewPr></p:cSldViewPr></p:slideViewPr>
        <p:gridSpacing cx="76200" cy="76200"/>
        </p:viewPr>
        """
    }

    private var tableStylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>
        """
    }

    private var corePropertiesXML: String {
        let title = xmlEscape(spec.title)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(title)</dc:title><dc:creator>Iexa</dc:creator><cp:lastModifiedBy>Iexa</cp:lastModifiedBy><cp:revision>1</cp:revision>
        <dcterms:created xsi:type="dcterms:W3CDTF">2026-06-04T00:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-06-04T00:00:00Z</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private var appPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <Application>Iexa</Application><PresentationFormat>On-screen Show (16:9)</PresentationFormat><Slides>\(renderedSlides.count)</Slides><Notes>0</Notes><HiddenSlides>0</HiddenSlides><MMClips>0</MMClips><ScaleCrop>false</ScaleCrop>
        <HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Slide Titles</vt:lpstr></vt:variant><vt:variant><vt:i4>\(renderedSlides.count)</vt:i4></vt:variant></vt:vector></HeadingPairs>
        <TitlesOfParts><vt:vector size="\(max(renderedSlides.count, 1))" baseType="lpstr">\(renderedSlides.isEmpty ? "<vt:lpstr>\(xmlEscape(spec.title))</vt:lpstr>" : renderedSlides.map { "<vt:lpstr>\(xmlEscape($0.slide.title))</vt:lpstr>" }.joined())</vt:vector></TitlesOfParts>
        <Company></Company><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>16.0000</AppVersion>
        </Properties>
        """
    }

    private func slideRelationships(index: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(index + 1).png"/>
        </Relationships>
        """
    }

    private func slideXML(index: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:cSld>
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        <p:pic>
        <p:nvPicPr><p:cNvPr id="2" name="Picture \(index + 1)" descr="slide-preview-\(index + 1).png"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
        <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
        </p:pic>
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }
}

private func columnName(_ index: Int) -> String {
    var value = index + 1
    var result = ""
    while value > 0 {
        let remainder = (value - 1) % 26
        result = String(UnicodeScalar(UInt32(65 + remainder))!) + result
        value = (value - 1) / 26
    }
    return result
}

private func xmlEscape(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private struct OfficeZipEntry: Sendable {
    let path: String
    let data: Data

    static func text(_ path: String, _ text: String) -> OfficeZipEntry {
        OfficeZipEntry(path: path, data: Data(text.utf8))
    }
}

private struct OfficeZipWriter {
    let entries: [OfficeZipEntry]

    func write(to url: URL) throws {
        var output = Data()
        var central = Data()
        for entry in entries {
            let localOffset = UInt32(output.count)
            let nameData = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            output.appendUInt32(0x04034b50)
            output.appendUInt16(20)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(crc)
            output.appendUInt32(UInt32(entry.data.count))
            output.appendUInt32(UInt32(entry.data.count))
            output.appendUInt16(UInt16(nameData.count))
            output.appendUInt16(0)
            output.append(nameData)
            output.append(entry.data)

            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(entry.data.count))
            central.appendUInt32(UInt32(entry.data.count))
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(localOffset)
            central.append(nameData)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(UInt32(central.count))
        output.appendUInt32(centralOffset)
        output.appendUInt16(0)
        try output.write(to: url, options: .atomic)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF)
        ])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
