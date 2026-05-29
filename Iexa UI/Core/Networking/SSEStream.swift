import Foundation

/// Parses a `URLSession.AsyncBytes` stream as Server-Sent Events (SSE).
///
/// Yields individual SSE data payloads as strings, handling the `data:` prefix
/// and the `[DONE]` terminator used by OpenAI-compatible APIs.
///
/// Uses `AsyncBytes.lines` for correct UTF-8 line splitting, avoiding
/// the byte-by-byte `UnicodeScalar` approach that corrupts multi-byte
/// characters (emoji, CJK, accented Latin, etc.).
struct SSEStream: AsyncSequence {
    typealias Element = SSEEvent

    let bytes: URLSession.AsyncBytes

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        /// Uses the UTF-8–aware line iterator provided by Foundation.
        var lineIterator: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        private var finished = false

        init(bytes: URLSession.AsyncBytes) {
            self.lineIterator = bytes.lines.makeAsyncIterator()
        }

        mutating func next() async throws -> SSEEvent? {
            if finished { return nil }

            while true {
                guard let line = try await lineIterator.next() else {
                    // Byte stream ended (server closed connection)
                    finished = true
                    return nil
                }

                // Preserve leading spaces. Some compatible providers stream raw
                // text lines or code deltas where indentation is significant.
                let eventLine = line.trimmingCharacters(in: .newlines)

                // Empty line = end of event block in SSE; skip
                if eventLine.isEmpty { continue }

                if let event = parseSSELine(eventLine) {
                    // Don't set `finished` on [DONE] – let the natural
                    // byte-stream close (server closes connection after
                    // the final [DONE]) terminate the iteration.  This
                    // makes the stream resilient to intermediate [DONE]
                    // markers that some servers send between tool calls
                    // and continuations.
                    return event
                }
            }
        }

        private func parseSSELine(_ line: String) -> SSEEvent? {
            // Handle [DONE] terminator
            if line == "[DONE]" || line == "data: [DONE]" {
                return .done
            }

            // Standard SSE field parsing
            if line.hasPrefix("data:") {
                var payloadStart = line.index(line.startIndex, offsetBy: 5)
                if payloadStart < line.endIndex, line[payloadStart] == " " {
                    payloadStart = line.index(after: payloadStart)
                }
                let payload = String(line[payloadStart...])
                if payload == "[DONE]" {
                    return .done
                }
                // Try parsing as JSON
                if let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return .json(json)
                }
                return .text(payload)
            }

            if line.hasPrefix("event: ") {
                let eventName = String(line.dropFirst(7))
                return .event(name: eventName)
            }

            if line.hasPrefix("id: ") {
                // SSE event ID, typically ignored for chat
                return nil
            }

            if line.hasPrefix("retry: ") {
                // SSE reconnection interval, ignored
                return nil
            }

            // Lines starting with ":" are SSE comments (keepalive)
            if line.hasPrefix(":") {
                return nil
            }

            // Raw text not matching SSE format
            if !line.isEmpty {
                if (line.hasPrefix("{") || line.hasPrefix("[")),
                   let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return .json(json)
                }
                return .text(line)
            }

            return nil
        }
    }
}

/// A parsed SSE event.
enum SSEEvent: Sendable {
    /// A JSON data payload from a `data:` field.
    case json([String: Any])
    /// A plain text data payload.
    case text(String)
    /// An event type field (`event: name`).
    case event(name: String)
    /// The `[DONE]` terminator signaling end of stream.
    case done

    // MARK: - Convenience

    /// Extracts the content delta from an OpenAI-style streaming chunk.
    var contentDelta: String? {
        if case .text(let text) = self {
            return text.isEmpty ? nil : text
        }

        guard case .json(let json) = self else { return nil }
        if let type = json["type"] as? String {
            if (type == "response.output_text.delta" || type == "response.refusal.delta"),
               let delta = json["delta"] as? String,
               !delta.isEmpty {
                return delta
            }
        }
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any] {
            if let content = Self.renderContent(delta["content"]) {
                return content
            }
            if let imageReference = Self.firstImageReference(in: delta) {
                return Self.markdownImage(imageReference)
            }
        }
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any] {
            if let content = Self.renderContent(message["content"]) {
                return content
            }
            if let imageReference = Self.firstImageReference(in: message) {
                return Self.markdownImage(imageReference)
            }
        }
        if json["type"] as? String == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String {
            return text
        }
        if let content = Self.renderContent(json["content"]) {
            return content
        }
        if let text = json["text"] as? String, !text.isEmpty {
            return text
        }
        if let imageReference = Self.firstImageReference(in: json) {
            return Self.markdownImage(imageReference)
        }
        return nil
    }

    /// Extracts reasoning/thinking deltas from compatible provider chunks.
    var reasoningDelta: String? {
        guard case .json(let json) = self else { return nil }

        if let type = json["type"] as? String,
           [
            "response.reasoning_text.delta",
            "response.reasoning.delta",
            "response.output_reasoning.delta"
           ].contains(type),
           let delta = json["delta"] as? String,
           !delta.isEmpty {
            return delta
        }

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let reasoning = Self.renderReasoning(delta) {
                return reasoning
            }
            if let message = first["message"] as? [String: Any],
               let reasoning = Self.renderReasoning(message) {
                return reasoning
            }
        }

        if json["type"] as? String == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           ["thinking_delta", "reasoning_delta"].contains(delta["type"] as? String ?? ""),
           let text = (delta["thinking"] as? String) ?? (delta["text"] as? String),
           !text.isEmpty {
            return text
        }

        return Self.renderReasoning(json)
    }

    /// Extracts usage statistics from the final streaming chunk.
    var usage: [String: Any]? {
        guard case .json(let json) = self else { return nil }
        return Self.extractUsage(from: json)
    }

    /// Whether this chunk indicates the response is complete.
    var isFinished: Bool {
        switch self {
        case .done:
            return true
        case .json(let json):
            if let type = json["type"] as? String,
               type == "message_stop" || type == "response.completed"
                || type == "response.incomplete" || type == "response.failed" {
                return true
            }
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let finishReason = first["finish_reason"] as? String,
               !finishReason.isEmpty {
                return true
            }
            return false
        default:
            return false
        }
    }

    private static func renderContent(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            if let imageReference = firstImageReferenceInText(text) {
                return text.contains(imageReference) ? text : markdownImage(imageReference)
            }
            if looksLikeBase64Image(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return markdownImage("data:image/png;base64,\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return text.isEmpty ? nil : text
        }

        if let dict = value as? [String: Any] {
            if let imageReference = firstImageReference(in: dict) {
                return markdownImage(imageReference)
            }
            for key in ["text", "content", "value"] {
                if let rendered = renderContent(dict[key]) {
                    return rendered
                }
            }
            return nil
        }

        if let array = value as? [Any] {
            let rendered = array.compactMap { renderContent($0) }.joined()
            return rendered.isEmpty ? nil : rendered
        }

        return nil
    }

    private static func renderReasoning(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            return text.isEmpty ? nil : text
        }

        if let dict = value as? [String: Any] {
            for key in [
                "reasoning_content", "reasoningContent",
                "reasoning", "thinking", "think",
                "thought", "thoughts"
            ] {
                if let rendered = renderReasoning(dict[key]) {
                    return rendered
                }
            }
            return nil
        }

        if let array = value as? [Any] {
            let rendered = array.compactMap { renderReasoning($0) }.joined()
            return rendered.isEmpty ? nil : rendered
        }

        return nil
    }

    private static func extractUsage(from json: [String: Any]) -> [String: Any]? {
        let usageKeys = [
            "usage",
            "token_usage",
            "tokenUsage",
            "response_usage",
            "responseUsage",
            "usage_metadata",
            "usageMetadata"
        ]
        for key in usageKeys {
            if let usage = json[key] as? [String: Any], !usage.isEmpty {
                return usage
            }
        }

        if let message = json["message"] as? [String: Any],
           let usage = extractUsage(from: message) {
            return usage
        }
        if let delta = json["delta"] as? [String: Any],
           let usage = extractUsage(from: delta) {
            return usage
        }
        if let response = json["response"] as? [String: Any],
           let usage = extractUsage(from: response) {
            return usage
        }
        if let choices = json["choices"] as? [[String: Any]] {
            for choice in choices {
                if let usage = extractUsage(from: choice) {
                    return usage
                }
            }
        }

        return nil
    }

    private static func markdownImage(_ reference: String) -> String {
        "\n\n![image](\(reference))\n\n"
    }

    private static func firstImageReference(in value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
               let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let nested = firstImageReference(in: json) {
                return nested
            }
            if trimmed.hasPrefix("data:image/") {
                return trimmed
            }
            if let inText = firstImageReferenceInText(trimmed) {
                return inText
            }
            if looksLikeBase64Image(trimmed) {
                return "data:image/png;base64,\(trimmed)"
            }
            return nil
        }

        if let dict = value as? [String: Any] {
            let typeHint = [
                dict["type"], dict["mime_type"], dict["mimeType"],
                dict["content_type"], dict["contentType"]
            ].compactMap { $0.map { "\($0)" } }
                .joined(separator: " ")
                .lowercased()

            if typeHint.contains("image"),
               let base64 = dict["data"] as? String,
               looksLikeBase64Image(base64) {
                let mimeType = (dict["mime_type"] as? String)
                    ?? (dict["mimeType"] as? String)
                    ?? (dict["content_type"] as? String)
                    ?? (dict["contentType"] as? String)
                    ?? "image/png"
                return "data:\(mimeType);base64,\(base64)"
            }

            let directImageKeys = [
                "image_url", "imageUrl", "imageURL", "url",
                "file_url", "download_url", "output_url",
                "b64_json", "base64", "image_base64", "imageBase64",
                "image", "data", "generated_image", "generatedImage",
                "inline_data", "inlineData", "bytesBase64Encoded"
            ]
            for key in directImageKeys {
                if let raw = dict[key] as? String {
                    let allowsOpaqueImageURL = ["url", "image_url", "imageUrl", "imageURL", "file_url", "download_url", "output_url"]
                        .contains(key)
                    if let reference = explicitImageReference(raw, allowsOpaqueImageURL: allowsOpaqueImageURL) {
                        return reference
                    }
                }
                if let reference = firstImageReference(in: dict[key]) {
                    return reference
                }
            }

            for key in [
                "output", "images", "content", "contents", "result", "results",
                "response", "responses", "choices", "message", "messages",
                "candidates", "candidate", "parts", "part", "artifact",
                "artifacts", "asset", "assets", "media", "medias"
            ] {
                if let reference = firstImageReference(in: dict[key]) {
                    return reference
                }
            }

            return nil
        }

        if let array = value as? [Any] {
            for item in array {
                if let reference = firstImageReference(in: item) {
                    return reference
                }
            }
        }

        return nil
    }

    private static func explicitImageReference(_ raw: String, allowsOpaqueImageURL: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:image/") {
            return trimmed
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return (allowsOpaqueImageURL || isLikelyImageURL(trimmed)) ? trimmed : nil
        }
        if let inText = firstImageReferenceInText(trimmed) {
            return inText
        }
        if looksLikeBase64Image(trimmed) {
            return "data:image/png;base64,\(trimmed)"
        }
        return nil
    }

    private static func firstImageReferenceInText(_ text: String) -> String? {
        let patterns = [
            #"!\[[^\]]*\]\((data:image/[^)\s]+)\)"#,
            #"<img[^>]+src=["'](data:image/[^"']+)["']"#,
            #"<img[^>]+src=["'](https?://[^"']+\.(?:png|jpe?g|webp|gif|bmp|avif|svg)(?:\?[^"']*)?)["']"#,
            #"(data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_-]{128,})"#,
            #"(https?://[^\s"'<>]+\.(?:png|jpe?g|webp|gif|bmp|avif|svg)(?:\?[^\s"'<>]+)?)"#,
            #"(https?://assets\.grok\.com/[^\s"'<>]+)"#,
            #"(?:"url"|"image_url"|"imageUrl"|"imageURL"|"download_url"|"output_url")\s*:\s*"(https?://[^"]+\.(?:png|jpe?g|webp|gif|bmp|avif|svg)(?:\?[^"]*)?)""#,
            #"(?:"b64_json"|"base64"|"image_base64"|"imageBase64")\s*:\s*"([A-Za-z0-9+/=_-]{128,})""#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1 else { continue }
            let value = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("data:image/") {
                return value
            }
            if value.hasPrefix("http://") || value.hasPrefix("https://") {
                if isLikelyImageURL(value) {
                    return value
                }
                continue
            }
            if looksLikeBase64Image(value) {
                return "data:image/png;base64,\(value)"
            }
        }

        return nil
    }

    private static func isLikelyImageURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let host = url.host?.lowercased() else { return false }
        let lower = value.lowercased()
        if lower.range(of: #"\.(png|jpe?g|webp|gif|bmp|avif|svg)(\?|$)"#, options: .regularExpression) != nil {
            return true
        }
        if lower.contains("data:image") || lower.contains("image/") {
            return true
        }
        if host == "assets.grok.com" {
            return true
        }
        let imageHosts = ["image", "img", "cdn", "asset", "media", "static", "file", "files"]
        if imageHosts.contains(where: { host.contains($0) }) {
            return true
        }
        let imagePathHints = ["/image", "/images", "/generated", "/media", "/asset", "/assets", "/file", "/files"]
        return imagePathHints.contains(where: { lower.contains($0) })
    }

    private static func looksLikeBase64Image(_ string: String) -> Bool {
        guard string.count > 128, !string.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        return string.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// Sendable conformance for [String: Any]
extension SSEEvent {
    // SSEEvent is marked @unchecked Sendable because the json dictionary
    // contains only Foundation JSON types which are all value types or
    // thread-safe reference types.
}
