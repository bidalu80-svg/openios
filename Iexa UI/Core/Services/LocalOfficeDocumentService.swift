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

@MainActor
final class LocalOfficeDocumentService {
    static let shared = LocalOfficeDocumentService()

    private let fileManager = FileManager.default

    private init() {}

    func createExcel(from call: [String: Any]) async throws -> LocalOfficeDocumentResult {
        let spec = ExcelSpec(call: call)
        let folder = try makeOutputFolder(prefix: "excel")
        let fileName = safeFileName(spec.fileName, fallback: "\(spec.title).xlsx", fileExtension: "xlsx")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")
        let previewURL = folder.appendingPathComponent("preview-1.png")

        let xlsx = try ExcelOpenXMLBuilder(spec: spec).build()
        try OfficeZipWriter(entries: xlsx).write(to: documentURL)
        try writeJSON(call, to: draftURL)
        try await renderExcelPreview(spec: spec, to: previewURL)

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

    func createPowerPoint(from call: [String: Any]) async throws -> LocalOfficeDocumentResult {
        let spec = PresentationSpec(call: call)
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

    func createWord(from call: [String: Any]) async throws -> LocalOfficeDocumentResult {
        let spec = WordSpec(call: call)
        let folder = try makeOutputFolder(prefix: "word")
        let fileName = safeFileName(spec.fileName, fallback: "\(spec.title).docx", fileExtension: "docx")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")

        let docx = try WordOpenXMLBuilder(spec: spec).build()
        try OfficeZipWriter(entries: docx).write(to: documentURL)
        try writeJSON(call, to: draftURL)

        var previewURLs: [URL] = []
        let previewImages = WordPreviewRenderer.renderPages(spec: spec)
        for (index, image) in previewImages.enumerated() {
            let previewURL = folder.appendingPathComponent("preview-\(index + 1).png")
            try writePNG(image, to: previewURL)
            previewURLs.append(previewURL)
        }

        return LocalOfficeDocumentResult(
            documentURL: documentURL,
            previewURLs: previewURLs,
            draftURL: draftURL,
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            documentType: "word",
            title: spec.title,
            summary: "已生成 Word：\(fileName)，共 \(spec.sections.count) 个章节、\(previewURLs.count) 页预览。",
            previewText: spec.previewText
        )
    }

    func createPDF(from call: [String: Any]) async throws -> LocalOfficeDocumentResult {
        let title = JSONValue.string(call["title"], fallback: "PDF 文档")
        let folder = try makeOutputFolder(prefix: "pdf")
        let fileName = safeFileName(JSONValue.string(call["file_name"]).nilIfEmpty, fallback: "\(title).pdf", fileExtension: "pdf")
        let documentURL = folder.appendingPathComponent(fileName)
        let draftURL = folder.appendingPathComponent("draft.json")

        let render = PDFRenderPlan(call: call)
        let pages = render.pages
        guard !pages.isEmpty else {
            throw OfficeDocumentError.renderFailed
        }
        try PDFDocumentRenderer.write(images: pages, title: render.title, to: documentURL)
        try writeJSON(call, to: draftURL)

        var previewURLs: [URL] = []
        for (index, image) in pages.enumerated() {
            let previewURL = folder.appendingPathComponent("preview-\(index + 1).png")
            try writePNG(image, to: previewURL)
            previewURLs.append(previewURL)
        }

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

    private func renderSlidePreview(slide: SlideSpec, index: Int, theme: PresentationTheme) -> UIImage {
        SlidePreviewRenderer.render(slide: slide, index: index, theme: theme)
    }
}

private enum OfficeDocumentError: LocalizedError {
    case documentsUnavailable
    case renderFailed
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            return "无法访问 Documents 目录。"
        case .renderFailed:
            return "文档预览图生成失败。"
        case .invalidArchive:
            return "Office 文件打包失败。"
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
    let sheets: [ExcelSheetSpec]

    init(call: [String: Any]) {
        title = JSONValue.string(call["title"], fallback: "Excel 报表")
        fileName = JSONValue.string(call["file_name"]).nilIfEmpty
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
        [
            JSONValue.string(call["style"]),
            JSONValue.string(call["design"]),
            JSONValue.string(call["background_style"]),
            JSONValue.string(call["theme"]),
            JSONValue.string(call["title"]),
            JSONValue.string(call["subtitle"])
        ].filter { !$0.isEmpty }.joined(separator: " ")
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
    }

    let style: Style
    let backgroundHex: String
    let primaryHex: String
    let accentHex: String
    let textHex: String
    let subtleHex: String

    init(raw: [String: Any]?, hint: String = "") {
        let styleHint = [
            JSONValue.string(raw?["style"]),
            JSONValue.string(raw?["preset"]),
            JSONValue.string(raw?["background_style"]),
            JSONValue.string(raw?["mood"]),
            hint
        ].filter { !$0.isEmpty }.joined(separator: " ")
        style = Self.style(from: styleHint)
        let palette = Self.palette(for: style)
        backgroundHex = Self.hex(raw?["background"], fallback: palette.background)
        primaryHex = Self.hex(raw?["primary"], fallback: palette.primary)
        accentHex = Self.hex(raw?["accent"], fallback: palette.accent)
        textHex = Self.hex(raw?["text"], fallback: palette.text)
        subtleHex = Self.hex(raw?["subtle"], fallback: palette.subtle)
    }

    private static func hex(_ value: Any?, fallback: String) -> String {
        let raw = JSONValue.string(value, fallback: fallback)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let hexCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard raw.count == 6, raw.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) else { return fallback }
        return raw
    }

    private static func style(from text: String) -> Style {
        let lower = text.lowercased()
        if lower.contains("深蓝") || lower.contains("navy") || lower.contains("deep blue") || lower.contains("deep_blue") { return .deepBlue }
        if lower.contains("科技") || lower.contains("tech") || lower.contains("ai") || lower.contains("cyber") { return .tech }
        if lower.contains("暗") || lower.contains("黑") || lower.contains("dark") { return .dark }
        if lower.contains("暖") || lower.contains("橙") || lower.contains("红") || lower.contains("warm") || lower.contains("orange") { return .warm }
        if lower.contains("绿色") || lower.contains("环保") || lower.contains("生态") || lower.contains("green") { return .green }
        if lower.contains("紫") || lower.contains("violet") || lower.contains("purple") { return .violet }
        if lower.contains("极简") || lower.contains("简洁") || lower.contains("minimal") || lower.contains("clean") { return .minimal }
        return .modern
    }

    private static func palette(for style: Style) -> (background: String, primary: String, accent: String, text: String, subtle: String) {
        switch style {
        case .modern:
            return ("F7F8FA", "111827", "2563EB", "111827", "6B7280")
        case .minimal:
            return ("FFFFFF", "111827", "111827", "111827", "6B7280")
        case .deepBlue:
            return ("071326", "EAF2FF", "3B82F6", "F8FAFC", "B6C6E3")
        case .tech:
            return ("08111F", "ECFEFF", "22D3EE", "F8FAFC", "A7F3D0")
        case .dark:
            return ("111827", "F9FAFB", "60A5FA", "F9FAFB", "D1D5DB")
        case .warm:
            return ("FFF7ED", "2F241D", "EA580C", "1F2937", "78716C")
        case .green:
            return ("F0FDF4", "113124", "16A34A", "102A1D", "4B6357")
        case .violet:
            return ("F5F3FF", "2E1065", "7C3AED", "1F163D", "6D5D8A")
        }
    }

    var backgroundColor: UIColor { UIColor(hex: backgroundHex) }
    var primaryColor: UIColor { UIColor(hex: primaryHex) }
    var accentColor: UIColor { UIColor(hex: accentHex) }
    var textColor: UIColor { UIColor(hex: textHex) }
    var subtleColor: UIColor { UIColor(hex: subtleHex) }
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

    private static func themeHint(from call: [String: Any]) -> String {
        [
            JSONValue.string(call["style"]),
            JSONValue.string(call["design"]),
            JSONValue.string(call["background_style"]),
            JSONValue.string(call["theme"]),
            JSONValue.string(call["title"]),
            JSONValue.string(call["subtitle"])
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct WordSectionSpec: Sendable {
    let heading: String
    let paragraphs: [String]
    let bullets: [String]
}

private struct DocumentTheme: Sendable {
    let accentHex: String
    let titleHex: String
    let textHex: String
    let subtleHex: String

    init(raw: [String: Any]?, hint: String = "") {
        let presentationTheme = PresentationTheme(raw: raw, hint: hint)
        accentHex = presentationTheme.accentHex
        titleHex = presentationTheme.style == .dark || presentationTheme.style == .deepBlue || presentationTheme.style == .tech
            ? "111827"
            : presentationTheme.primaryHex
        textHex = "111827"
        subtleHex = "6B7280"
    }

    var accentColor: UIColor { UIColor(hex: accentHex) }
    var titleColor: UIColor { UIColor(hex: titleHex) }
    var textColor: UIColor { UIColor(hex: textHex) }
    var subtleColor: UIColor { UIColor(hex: subtleHex) }
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
            UIColor(hex: "F7F8FA").setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .bold),
                .foregroundColor: UIColor(hex: "111827")
            ]
            spec.title.draw(in: CGRect(x: 56, y: 38, width: 900, height: 60), withAttributes: titleAttrs)

            guard let sheet = spec.sheets.first else { return }
            let headers = sheet.headers.isEmpty
                ? (sheet.rows.first?.indices.map { "列 \($0 + 1)" } ?? ["内容"])
                : sheet.headers
            let rows = Array(sheet.rows.prefix(8))
            let tableRect = CGRect(x: 56, y: 130, width: 1088, height: 440)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: tableRect, cornerRadius: 18).fill()
            UIColor(hex: "D1D5DB").setStroke()
            UIBezierPath(roundedRect: tableRect, cornerRadius: 18).stroke()

            let columnCount = max(1, min(headers.count, 6))
            let colWidth = tableRect.width / CGFloat(columnCount)
            let rowHeight: CGFloat = 48
            for rowIndex in 0...(rows.count) {
                let y = tableRect.minY + CGFloat(rowIndex) * rowHeight
                let fill = rowIndex == 0 ? UIColor(hex: "EEF2FF") : (rowIndex % 2 == 0 ? UIColor(hex: "F9FAFB") : UIColor.white)
                fill.setFill()
                UIBezierPath(rect: CGRect(x: tableRect.minX, y: y, width: tableRect.width, height: rowHeight)).fill()
                for colIndex in 0..<columnCount {
                    let text = rowIndex == 0
                        ? headers[safe: colIndex] ?? ""
                        : rows[safe: rowIndex - 1]?[safe: colIndex] ?? ""
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: rowIndex == 0 ? 22 : 20, weight: rowIndex == 0 ? .semibold : .regular),
                        .foregroundColor: UIColor(hex: rowIndex == 0 ? "1D4ED8" : "111827")
                    ]
                    text.draw(
                        in: CGRect(x: tableRect.minX + CGFloat(colIndex) * colWidth + 14, y: y + 12, width: colWidth - 22, height: rowHeight - 12),
                        withAttributes: attrs
                    )
                }
            }

            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor(hex: "6B7280")
            ]
            "本地 Office Agent · \(spec.sheets.count) 个工作表 · \(sheet.rows.count) 行".draw(
                in: CGRect(x: 56, y: 600, width: 1000, height: 32),
                withAttributes: footerAttrs
            )
        }
    }
}

private struct SlidePreviewRenderer {
    static func render(slide: SlideSpec, index: Int, theme: PresentationTheme) -> UIImage {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let isCover = slide.layout.lowercased().contains("cover") || index == 0
            drawBackground(context.cgContext, size: size, theme: theme, index: index, isCover: isCover)

            let isDark = theme.style == .deepBlue || theme.style == .tech || theme.style == .dark
            let titleSize: CGFloat = isCover ? (isDark ? 68 : 64) : 46
            let titleX: CGFloat = isDark ? 110 : (theme.style == .minimal ? 82 : 96)
            let titleY: CGFloat = isCover ? (isDark ? 178 : 190) : 78
            let titleRect = CGRect(x: titleX, y: titleY, width: isDark ? 980 : 940, height: isCover ? 166 : 80)
            drawText(slide.title, in: titleRect, font: .systemFont(ofSize: titleSize, weight: .bold), color: theme.textColor)

            if !slide.subtitle.isEmpty {
                drawText(
                    slide.subtitle,
                    in: CGRect(x: titleX + 4, y: isCover ? (isDark ? 350 : 348) : 138, width: isDark ? 900 : 860, height: 70),
                    font: .systemFont(ofSize: isCover ? 30 : 22, weight: .medium),
                    color: theme.subtleColor
                )
            }

            if !isCover {
                if !slide.table.isEmpty {
                    drawTable(slide.table, origin: CGPoint(x: 100, y: 220), width: 980, theme: theme)
                } else {
                    drawBullets(slide.bullets, origin: CGPoint(x: 120, y: 220), width: 920, theme: theme)
                }
            }

            let pageAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: theme.subtleColor
            ]
            "\(index + 1)".draw(in: CGRect(x: 1120, y: 640, width: 80, height: 30), withAttributes: pageAttrs)
        }
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
        case .deepBlue:
            drawGradient(context, bounds: bounds, startHex: "061020", endHex: "102A6B")
            drawDiagonalBand(context, points: [
                CGPoint(x: 820, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 1040, y: size.height)
            ], color: theme.accentColor.withAlphaComponent(0.22))
            drawRule(x: 64, y: 72, width: 8, height: 540, color: theme.accentColor)
            drawTopKicker(context, size: size, theme: theme, text: isCover ? "IEXA DECK" : "SECTION \(index + 1)")
        case .tech:
            drawGradient(context, bounds: bounds, startHex: "06111F", endHex: "0F172A")
            drawGrid(context, size: size, color: theme.accentColor.withAlphaComponent(0.16), step: 44)
            drawDiagonalBand(context, points: [
                CGPoint(x: 860, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: 250), CGPoint(x: 980, y: 350)
            ], color: theme.accentColor.withAlphaComponent(0.24))
            drawRule(x: 74, y: 84, width: 118, height: 6, color: theme.accentColor)
            drawTopKicker(context, size: size, theme: theme, text: "AI WORKFLOW")
        case .dark:
            UIColor(hex: theme.backgroundHex).setFill()
            context.fill(bounds)
            drawDiagonalBand(context, points: [
                CGPoint(x: 0, y: 530), CGPoint(x: size.width, y: 430),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)
            ], color: UIColor.white.withAlphaComponent(0.06))
            drawRule(x: 70, y: 70, width: 150, height: 7, color: theme.accentColor)
        case .minimal:
            UIColor.white.setFill()
            context.fill(bounds)
            drawRule(x: 76, y: 76, width: 1120, height: 2, color: UIColor(hex: "111827").withAlphaComponent(0.16))
            drawRule(x: 76, y: 616, width: 180, height: 4, color: theme.accentColor)
        case .warm:
            UIColor(hex: theme.backgroundHex).setFill()
            context.fill(bounds)
            drawDiagonalBand(context, points: [
                CGPoint(x: 0, y: 0), CGPoint(x: 330, y: 0),
                CGPoint(x: 220, y: size.height), CGPoint(x: 0, y: size.height)
            ], color: UIColor(hex: "FED7AA").withAlphaComponent(0.72))
            drawRule(x: 82, y: 72, width: 8, height: 530, color: theme.accentColor)
            drawRule(x: 1018, y: 92, width: 142, height: 142, color: UIColor(hex: "FDBA74").withAlphaComponent(0.35))
        case .green:
            UIColor(hex: theme.backgroundHex).setFill()
            context.fill(bounds)
            drawDiagonalBand(context, points: [
                CGPoint(x: 920, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 780, y: size.height)
            ], color: UIColor(hex: "BBF7D0").withAlphaComponent(0.58))
            drawRule(x: 70, y: 72, width: 8, height: 540, color: theme.accentColor)
            drawRule(x: 96, y: 612, width: 280, height: 5, color: theme.accentColor.withAlphaComponent(0.55))
        case .violet:
            UIColor(hex: theme.backgroundHex).setFill()
            context.fill(bounds)
            drawDiagonalBand(context, points: [
                CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: 150), CGPoint(x: 0, y: 250)
            ], color: UIColor(hex: "DDD6FE").withAlphaComponent(0.72))
            drawRule(x: 74, y: 86, width: 132, height: 8, color: theme.accentColor)
            drawRule(x: 74, y: 106, width: 68, height: 8, color: theme.accentColor.withAlphaComponent(0.5))
        case .modern:
            UIColor(hex: theme.backgroundHex).setFill()
            context.fill(bounds)
            drawRule(x: 56, y: 52, width: 9, height: 560, color: theme.accentColor)
            drawDiagonalBand(context, points: [
                CGPoint(x: 1000, y: 0), CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: 255), CGPoint(x: 1088, y: 300)
            ], color: theme.accentColor.withAlphaComponent(0.12))
        }
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

    private static func drawTable(_ table: [[String]], origin: CGPoint, width: CGFloat, theme: PresentationTheme) {
        let rows = Array(table.prefix(6))
        let columns = max(1, min(rows.map(\.count).max() ?? 1, 5))
        let colWidth = width / CGFloat(columns)
        let rowHeight: CGFloat = 58
        let dark = theme.style == .deepBlue || theme.style == .tech || theme.style == .dark
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

    private static func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
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
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: pageSize))

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
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><sz val="11"/><color rgb="FF2563EB"/><name val="Arial"/></font></fonts>
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEFF6FF"/></patternFill></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """
    }

    private func worksheetXML(sheet: ExcelSheetSpec) -> String {
        let headers = sheet.headers
        var rows: [[String]] = []
        if !headers.isEmpty { rows.append(headers) }
        rows.append(contentsOf: sheet.rows)
        if rows.isEmpty {
            rows = [[sheet.name]]
        }
        let rowXML = rows.enumerated().map { rowIndex, row in
            let number = rowIndex + 1
            let cells = row.enumerated().map { columnIndex, value in
                let ref = "\(columnName(columnIndex))\(number)"
                let style = rowIndex == 0 && !headers.isEmpty ? #" s="1""# : ""
                return "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
            }.joined()
            return "<row r=\"\(number)\">\(cells)</row>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
        \(rowXML)
        </sheetData>
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

    func build() throws -> [OfficeZipEntry] {
        [
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
    }

    private var contentTypes: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
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
        </Relationships>
        """
    }

    private var documentXML: String {
        let paragraphs = documentParagraphs.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>
        \(paragraphs)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/><w:cols w:space="708"/><w:docGrid w:linePitch="360"/></w:sectPr>
        </w:body>
        </w:document>
        """
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
        <w:p><w:pPr><w:pStyle w:val="\(style)"/></w:pPr><w:r><w:t>\(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Aptos" w:eastAsia="PingFang SC" w:hAnsi="Aptos"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:color w:val="\(spec.theme.textHex)"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
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
