import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os.log
import ImageIO

/// Manages file attachment handling for chats and notes, including
/// image picking, document selection, and file upload to the server.
@MainActor @Observable
final class FileAttachmentService {

    // MARK: - State

    /// Pending attachments ready to be sent.
    private(set) var pendingAttachments: [ChatAttachment] = []

    /// Whether a file operation is in progress.
    private(set) var isProcessing: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "FileAttachment")
    private var conversationManager: ConversationManager?

    private struct FileEntry {
        let id: UUID
        let url: URL
        let data: Data
        let isImage: Bool
    }

    // MARK: - Configuration

    func configure(with manager: ConversationManager) {
        self.conversationManager = manager
    }

    // MARK: - Image Handling

    /// Processes selected photos from PhotosPicker.
    /// Automatically converts HEIC/HEIF/DNG/RAW images to JPEG for
    /// compatibility with vision models that don't support these formats.
    /// Immediately begins uploading each photo to the server.
    func processPhotos(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let (convertedData, fileName) = await Self.convertToJPEGIfNeeded(
                        data: data,
                        originalName: "Photo_\(Date.now.timeIntervalSince1970).jpg"
                    )
                    let image = UIImage(data: convertedData)
                    let thumbnail = image.map { Image(uiImage: $0) }

                    var attachment = ChatAttachment(
                        type: .image,
                        name: fileName,
                        thumbnail: thumbnail,
                        data: convertedData
                    )
                    attachment.uploadStatus = .uploading
                    pendingAttachments.append(attachment)

                    // Start upload immediately in background
                    let attachmentId = attachment.id
                    Task { await self.uploadAttachment(id: attachmentId) }
                }
            } catch {
                logger.error("Failed to load photo: \(error.localizedDescription)")
            }
        }
    }

    /// Processes a file URL (from document picker or share extension).
    /// Automatically converts HEIC/HEIF/DNG/RAW images to JPEG.
    /// Immediately begins uploading + processing on the server.
    func processFileURL(_ url: URL) async {
        isProcessing = true
        defer { isProcessing = false }

        guard url.startAccessingSecurityScopedResource() else {
            logger.error("Cannot access security-scoped resource: \(url.path)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? await Self.readFileData(from: url) else {
            logger.error("Failed to read file data: \(url.path)")
            return
        }

        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false

        if isImage {
            let (convertedData, fileName) = await Self.convertToJPEGIfNeeded(
                data: data,
                originalName: url.lastPathComponent
            )
            let thumbnail: Image? = UIImage(data: convertedData).map { Image(uiImage: $0) }
            var attachment = ChatAttachment(
                type: .image,
                name: fileName,
                thumbnail: thumbnail,
                data: convertedData
            )
            attachment.uploadStatus = .uploading
            pendingAttachments.append(attachment)

            let attachmentId = attachment.id
            Task { await self.uploadAttachment(id: attachmentId) }
        } else {
            var attachment = ChatAttachment(
                type: .file,
                name: url.lastPathComponent,
                thumbnail: nil,
                data: data
            )
            attachment.uploadStatus = .uploading
            pendingAttachments.append(attachment)

            let attachmentId = attachment.id
            Task { await self.uploadAttachment(id: attachmentId) }
        }
    }

    /// Processes multiple file URLs.
    /// When 2 or more non-image files are selected they are uploaded in parallel
    /// and then submitted to the server as a single batch-processing request,
    /// which is faster than N individual upload+SSE-poll calls.
    func processFileURLs(_ urls: [URL]) async {
        guard urls.count > 1 else {
            // Single file — use the existing path (upload + SSE poll).
            if let url = urls.first { await processFileURL(url) }
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        // ── 1. Read file data and classify URLs ───────────────────────────────
        // Build FileEntry + add placeholder attachment in one pass so the
        // entry.id always matches the attachment's auto-generated UUID.
        var entries: [FileEntry] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                logger.error("Cannot access security-scoped resource: \(url.path)")
                continue
            }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? await Self.readFileData(from: url) else {
                logger.error("Failed to read file data: \(url.path)")
                continue
            }
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false

            // ── 2. Add placeholder attachment and capture its UUID ────────────
            var attachment: ChatAttachment
            if isImage {
                let (convertedData, fileName) = await Self.convertToJPEGIfNeeded(
                    data: data,
                    originalName: url.lastPathComponent
                )
                let thumbnail: Image? = UIImage(data: convertedData).map { Image(uiImage: $0) }
                attachment = ChatAttachment(
                    type: .image,
                    name: fileName,
                    thumbnail: thumbnail,
                    data: convertedData
                )
                attachment.uploadStatus = .uploading
                pendingAttachments.append(attachment)
                entries.append(FileEntry(id: attachment.id, url: url, data: convertedData, isImage: true))
            } else {
                attachment = ChatAttachment(
                    type: .file,
                    name: url.lastPathComponent,
                    thumbnail: nil,
                    data: data
                )
                attachment.uploadStatus = .uploading
                pendingAttachments.append(attachment)
                entries.append(FileEntry(id: attachment.id, url: url, data: data, isImage: false))
            }
        }

        // ── 3. Images: upload individually (no server-side processing needed) ─
        let imageEntries = entries.filter { $0.isImage }
        let docEntries   = entries.filter { !$0.isImage }

        for entry in imageEntries {
            Task { await self.uploadAttachment(id: entry.id) }
        }

        // ── 4. Documents: single file → existing path; 2+ → batch ────────────
        if docEntries.count == 1 {
            Task { await self.uploadAttachment(id: docEntries[0].id) }
        } else if docEntries.count > 1 {
            Task { await self.uploadAndBatchProcess(entries: docEntries) }
        }
    }

    // MARK: - Batch Upload + Process

    /// Uploads each document without individual processing, then calls the
    /// batch-processing endpoint once for all of them.
    private func uploadAndBatchProcess(entries: [FileEntry]) async {
        guard let manager = conversationManager else {
            for entry in entries {
                updateAttachmentStatus(id: entry.id, status: .error, error: "Not connected to server")
            }
            return
        }

        // ── Phase 1: parallel upload (no processing) ─────────────────────────
        // Each element: (attachmentId, fileObject) or nil on failure
        typealias UploadResult = (id: UUID, fileObject: [String: Any])?

        var fileObjects: [[String: Any]] = []
        var idToFileId: [UUID: String] = [:]

        await withTaskGroup(of: UploadResult.self) { group in
            for entry in entries {
                let entryId = entry.id
                let entryData = entry.data
                let entryName = entry.url.lastPathComponent
                group.addTask {
                    do {
                        let fileObj = try await manager.uploadFileOnly(
                            data: entryData,
                            fileName: entryName
                        )
                        return (id: entryId, fileObject: fileObj)
                    } catch {
                        let msg = (error as? APIError).flatMap {
                            if case .httpError(_, let m, _) = $0 { return m } else { return nil }
                        } ?? error.localizedDescription
                        await MainActor.run {
                            self.updateAttachmentStatus(id: entryId, status: .error, error: msg)
                        }
                        self.logger.error("Batch upload failed for \(entryName): \(msg)")
                        return nil
                    }
                }
            }

            for await result in group {
                guard let r = result else { continue }
                fileObjects.append(r.fileObject)
                if let fileId = r.fileObject["id"] as? String {
                    idToFileId[r.id] = fileId
                }
            }
        }

        // Mark all successfully uploaded files as .processing
        for (attachId, _) in idToFileId {
            updateAttachmentStatus(id: attachId, status: .processing)
        }

        guard !fileObjects.isEmpty else { return }

        // ── Phase 2: single batch-process call ────────────────────────────────
        let collectionName = "batch-\(UUID().uuidString)"
        do {
            let result = try await manager.processFilesBatch(
                fileObjects: fileObjects,
                collectionName: collectionName
            )

            // Map fileId → attachmentId for result routing
            let fileIdToAttachId = Dictionary(uniqueKeysWithValues: idToFileId.map { ($1, $0) })

            for fileId in result.successes {
                if let attachId = fileIdToAttachId[fileId] {
                    updateAttachmentStatus(id: attachId, status: .completed, fileId: fileId)
                }
            }
            for failure in result.errors {
                if let attachId = fileIdToAttachId[failure.fileId] {
                    updateAttachmentStatus(
                        id: attachId,
                        status: .error,
                        error: failure.error ?? "Processing failed"
                    )
                }
            }
            logger.info("Batch processed \(result.successes.count) files (\(result.errors.count) errors)")
        } catch {
            let msg = (error as? APIError).flatMap {
                if case .httpError(_, let m, _) = $0 { return m } else { return nil }
            } ?? error.localizedDescription
            logger.error("Batch processing call failed: \(msg)")
            // Fall back: mark each as error with the batch failure message
            for attachId in idToFileId.keys {
                updateAttachmentStatus(id: attachId, status: .error, error: msg)
            }
        }
    }

    // MARK: - Upload

    /// Whether all non-audio attachments have finished uploading + processing.
    var allAttachmentsReady: Bool {
        let nonAudio = pendingAttachments.filter { $0.type != .audio }
        guard !nonAudio.isEmpty else { return true }
        return nonAudio.allSatisfy { $0.isReady }
    }

    /// Whether any attachment is currently uploading or processing.
    var hasUploadingAttachments: Bool {
        pendingAttachments.contains { $0.isUploading }
    }

    /// Uploads a single attachment to the server immediately.
    /// Updates the attachment's status as it progresses through
    /// uploading → processing → completed (or error).
    ///
    /// For non-image files, two phases are shown:
    /// 1. `.uploading` — multipart POST in progress
    /// 2. `.processing` — file is on server, SSE polling for completion
    /// 3. `.completed` or `.error` — done
    private func uploadAttachment(id: UUID) async {
        guard let manager = conversationManager else {
            updateAttachmentStatus(id: id, status: .error, error: "Not connected to server")
            return
        }

        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }),
              let data = pendingAttachments[index].data else {
            return
        }

        let fileName = pendingAttachments[index].name

        // Mark as uploading
        updateAttachmentStatus(id: id, status: .uploading)

        do {
            // For non-images: transition to .processing once upload completes,
            // while waiting for the server's SSE processing poll.
            let (fileId, fileObject) = try await manager.uploadFile(
                data: data,
                fileName: fileName,
                onUploaded: { [weak self] _ in
                    // Called on the calling task's thread (non-isolated);
                    // dispatch back to MainActor to update @Observable state.
                    Task { @MainActor [weak self] in
                        self?.updateAttachmentStatus(id: id, status: .processing)
                    }
                }
            )
            updateAttachmentStatus(id: id, status: .completed, fileId: fileId, fileObject: fileObject)
            logger.info("Attachment \(fileName) uploaded and processed successfully")
        } catch {
            // Surface the server error message (e.g. transcription failure) to the user.
            let message: String
            if let apiError = error as? APIError,
               case .httpError(_, let msg, _) = apiError,
               let msg {
                message = msg
            } else {
                message = error.localizedDescription
            }
            logger.error("Failed to upload/process \(fileName): \(message)")
            updateAttachmentStatus(id: id, status: .error, error: message)
        }
    }

    /// Updates the upload status of an attachment by its ID.
    private func updateAttachmentStatus(
        id: UUID,
        status: ChatAttachment.UploadStatus,
        fileId: String? = nil,
        fileObject: [String: Any]? = nil,
        error: String? = nil
    ) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingAttachments[index].uploadStatus = status
        if let fileId { pendingAttachments[index].uploadedFileId = fileId }
        if let fileObject { pendingAttachments[index].uploadedFileObject = fileObject }
        if let error { pendingAttachments[index].uploadError = error }
    }

    /// Retries uploading a failed attachment.
    func retryUpload(attachmentId: UUID) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == attachmentId }),
              pendingAttachments[index].uploadStatus == .error else { return }

        pendingAttachments[index].uploadStatus = .uploading
        pendingAttachments[index].uploadError = nil
        Task { await uploadAttachment(id: attachmentId) }
    }

    /// Returns pre-uploaded file references for all completed attachments.
    /// Builds the rich web-UI-format file ref so the server can locate the image/file content.
    /// Used by ChatViewModel.sendMessage() instead of uploading at send time.
    func getUploadedFileRefs() -> [[String: Any]] {
        pendingAttachments.compactMap { attachment -> [String: Any]? in
            guard let fileId = attachment.uploadedFileId else { return nil }
            // Skip audio attachments — they're handled separately via transcription
            guard attachment.type != .audio else { return nil }

            let fileObject = attachment.uploadedFileObject ?? [:]
            let filename = attachment.name
            let isImage = attachment.type == .image
            let contentType: String = isImage ? "image/jpeg" : "application/octet-stream"
            let payloadType = isImage ? "image" : "file"
            let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0

            return [
                "type": payloadType,
                "file": fileObject.isEmpty ? [
                    "id": fileId,
                    "filename": filename,
                    "meta": ["name": filename, "content_type": contentType, "size": size]
                ] : fileObject,
                "id": fileId,
                "url": fileId,
                "name": filename,
                "status": "uploaded",
                "size": size,
                "error": "",
                "content_type": contentType
            ]
        }
    }

    // MARK: - Management

    /// Removes an attachment from the pending list.
    func removeAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Clears all pending attachments.
    func clearAttachments() {
        pendingAttachments.removeAll()
    }

    // MARK: - Previews

    /// Returns an icon name for the given file extension.
    static func iconForExtension(_ ext: String) -> String {
        guard let utType = UTType(filenameExtension: ext) else { return "doc" }
        if utType.conforms(to: .image) { return "photo" }
        if utType.conforms(to: .movie) { return "film" }
        if utType.conforms(to: .audio) { return "waveform" }
        if utType.conforms(to: .pdf) { return "doc.text" }
        if utType.conforms(to: .spreadsheet) { return "tablecells" }
        if utType.conforms(to: .presentation) { return "rectangle.stack" }
        if utType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if utType.conforms(to: .text) { return "doc.plaintext" }
        if utType.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }

    /// Formats a byte count for display.
    static func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Image Conversion

    private nonisolated static func readFileData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    /// File extensions that need conversion to JPEG for vision model compatibility.
    private nonisolated static var convertibleExtensions: Set<String> {
        ["heic", "heif", "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2", "webp"]
    }

    /// Converts HEIC/HEIF/DNG/RAW image data to JPEG if needed.
    /// Also enforces the 2 MP pixel cap so uploads always stay under the
    /// API's 5 MB image limit.
    /// Returns the (possibly converted) data and updated filename.
    private nonisolated static func convertToJPEGIfNeeded(data: Data, originalName: String) async -> (Data, String) {
        await Task.detached(priority: .userInitiated) {
            let ext = (originalName as NSString).pathExtension.lowercased()
            guard let capped = Self.downsampleJPEGData(from: data) else {
                return (data, originalName)
            }
            if Self.convertibleExtensions.contains(ext) {
                let baseName = (originalName as NSString).deletingPathExtension
                return (capped, baseName + ".jpg")
            }
            return (capped, originalName)
        }.value
    }

    // MARK: - Image Size Limit

    /// Maximum total pixels for uploaded images (2 megapixels).
    /// A 2 MP JPEG at 0.85 quality is typically 1-2 MB — well under the
    /// API's 5 MB limit — while retaining enough detail for vision models.
    private nonisolated static var maxPixels: CGFloat { 2_000_000 }

    /// Downsamples an image to ≤ 2 MP and returns JPEG data at 0.85 quality.
    /// If the image is already within the pixel budget, it is only re-encoded
    /// to JPEG (no resize). Returns the original data unchanged if decoding fails.
    nonisolated static func downsampleForUpload(data: Data, image: UIImage? = nil, logger: Logger? = nil) -> Data {
        if let jpegData = downsampleJPEGData(from: data, logger: logger) {
            return jpegData
        }
        guard let img = image else { return data }
        return downsampleForUpload(image: img, logger: logger)
    }

    /// Core implementation: downscale `UIImage` to ≤ 2 MP, encode as JPEG.
    nonisolated static func downsampleForUpload(image: UIImage, logger: Logger? = nil) -> Data {
        let w = image.size.width
        let h = image.size.height
        let totalPixels = w * h

        if totalPixels <= maxPixels {
            // Already small enough — just encode to JPEG
            return image.jpegData(compressionQuality: 0.85) ?? Data()
        }

        // Scale factor to reach exactly maxPixels
        let scale = sqrt(maxPixels / totalPixels)
        let newSize = CGSize(width: round(w * scale), height: round(h * scale))

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        let result = resized.jpegData(compressionQuality: 0.85) ?? Data()
        logger?.info("Downsampled image from \(Int(w))×\(Int(h)) to \(Int(newSize.width))×\(Int(newSize.height)) (\(result.count) bytes)")
        return result
    }

    nonisolated static func thumbnailJPEGData(from data: Data, maxPixelSize: Int = 224) -> Data? {
        downsampleJPEGData(from: data, maxPixelSize: maxPixelSize, compressionQuality: 0.78)
    }

    nonisolated static func thumbnailJPEGData(from image: UIImage, maxPixelSize: CGFloat = 224) -> Data? {
        let largestSide = max(image.size.width, image.size.height)
        let targetSize: CGSize
        if largestSide > maxPixelSize, largestSide > 0 {
            let scale = maxPixelSize / largestSide
            targetSize = CGSize(width: round(image.size.width * scale), height: round(image.size.height * scale))
        } else {
            targetSize = image.size
        }

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.78)
    }

    nonisolated static func writeImagePreviewToCache(
        data: Data,
        originalName: String,
        maxPixelSize: Int = 720
    ) -> String? {
        guard let previewData = downsampleJPEGData(
            from: data,
            maxPixelSize: maxPixelSize,
            compressionQuality: 0.82
        ) ?? (data.count <= 2_000_000 ? data : nil) else {
            return nil
        }

        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent("iexa-attachment-previews", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let baseName = (originalName as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeBase = baseName.isEmpty ? "image" : baseName
            let fileURL = directory.appendingPathComponent("\(safeBase)-\(UUID().uuidString).jpg")
            try previewData.write(to: fileURL, options: [.atomic])
            return fileURL.absoluteString
        } catch {
            return nil
        }
    }

    private nonisolated static func downsampleJPEGData(from data: Data, logger: Logger? = nil) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = pixelDimension(properties?[kCGImagePropertyPixelWidth])
        let height = pixelDimension(properties?[kCGImagePropertyPixelHeight])
        let maxPixelSize: Int
        if let width, let height, width > 0, height > 0 {
            let totalPixels = width * height
            let scale = totalPixels > maxPixels ? sqrt(maxPixels / totalPixels) : 1
            maxPixelSize = max(1, Int(ceil(max(width, height) * scale)))
        } else {
            maxPixelSize = Int(ceil(sqrt(maxPixels)))
        }

        guard let output = downsampleJPEGData(
            from: source,
            maxPixelSize: maxPixelSize,
            compressionQuality: 0.85
        ) else {
            return nil
        }

        if let width, let height, width * height > maxPixels {
            logger?.info("Downsampled image from \(Int(width))×\(Int(height)) to max \(maxPixelSize) px (\(output.count) bytes)")
        }
        return output
    }

    private nonisolated static func downsampleJPEGData(
        from data: Data,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        return downsampleJPEGData(
            from: source,
            maxPixelSize: maxPixelSize,
            compressionQuality: compressionQuality
        )
    }

    private nonisolated static func downsampleJPEGData(
        from source: CGImageSource,
        maxPixelSize: Int,
        compressionQuality: CGFloat
    ) -> Data? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private nonisolated static func pixelDimension(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        return nil
    }
}
