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
        theme = PresentationTheme(raw: call["theme"] as? [String: Any])
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
}

private struct PresentationTheme: Sendable {
    let backgroundHex: String
    let primaryHex: String
    let accentHex: String
    let textHex: String
    let subtleHex: String

    init(raw: [String: Any]?) {
        backgroundHex = Self.hex(raw?["background"], fallback: "F7F8FA")
        primaryHex = Self.hex(raw?["primary"], fallback: "111827")
        accentHex = Self.hex(raw?["accent"], fallback: "2563EB")
        textHex = Self.hex(raw?["text"], fallback: "111827")
        subtleHex = Self.hex(raw?["subtle"], fallback: "6B7280")
    }

    private static func hex(_ value: Any?, fallback: String) -> String {
        let raw = JSONValue.string(value, fallback: fallback)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let hexCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard raw.count == 6, raw.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) else { return fallback }
        return raw
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
            theme.backgroundColor.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))

            theme.accentColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: 56, y: 52, width: 9, height: 560), cornerRadius: 4).fill()
            UIBezierPath(ovalIn: CGRect(x: 1010, y: -140, width: 390, height: 390)).fill(with: .normal, alpha: 0.12)

            let isCover = slide.layout.lowercased().contains("cover") || index == 0
            let titleSize: CGFloat = isCover ? 64 : 46
            let titleRect = CGRect(x: 96, y: isCover ? 190 : 78, width: 940, height: isCover ? 160 : 80)
            drawText(slide.title, in: titleRect, font: .systemFont(ofSize: titleSize, weight: .bold), color: theme.textColor)

            if !slide.subtitle.isEmpty {
                drawText(
                    slide.subtitle,
                    in: CGRect(x: 100, y: isCover ? 348 : 138, width: 860, height: 70),
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
        for rowIndex in 0..<rows.count {
            let y = origin.y + CGFloat(rowIndex) * rowHeight
            (rowIndex == 0 ? theme.accentColor.withAlphaComponent(0.14) : UIColor.white.withAlphaComponent(0.62)).setFill()
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

private struct PowerPointOpenXMLBuilder {
    let spec: PresentationSpec
    let renderedSlides: [RenderedSlide]

    func build() throws -> [OfficeZipEntry] {
        var entries: [OfficeZipEntry] = []
        entries.append(.text("[Content_Types].xml", contentTypes))
        entries.append(.text("_rels/.rels", packageRelationships))
        entries.append(.text("ppt/presentation.xml", presentationXML))
        entries.append(.text("ppt/_rels/presentation.xml.rels", presentationRelationships))
        entries.append(.text("ppt/theme/theme1.xml", themeXML))
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
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(renderedSlides.indices.map { "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined(separator: "\n"))
        </Types>
        """
    }

    private var packageRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """
    }

    private var presentationXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <p:sldIdLst>
        \(renderedSlides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined(separator: "\n"))
        </p:sldIdLst>
        <p:sldSz cx="12192000" cy="6858000" type="screen16x9"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
    }

    private var presentationRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(renderedSlides.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined(separator: "\n"))
        <Relationship Id="rId\(renderedSlides.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        </Relationships>
        """
    }

    private var themeXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Iexa Office Agent">
        <a:themeElements>
        <a:clrScheme name="Iexa"><a:dk1><a:srgbClr val="111827"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:accent1><a:srgbClr val="\(spec.theme.accentHex)"/></a:accent1></a:clrScheme>
        <a:fontScheme name="Iexa"><a:majorFont><a:latin typeface="Aptos Display"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme>
        <a:fmtScheme name="Iexa"><a:fillStyleLst/><a:lnStyleLst/><a:effectStyleLst/><a:bgFillStyleLst/></a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }

    private func slideRelationships(index: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\(index + 1).png"/>
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
        <p:nvPicPr><p:cNvPr id="2" name="slide-preview-\(index + 1).png"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
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
