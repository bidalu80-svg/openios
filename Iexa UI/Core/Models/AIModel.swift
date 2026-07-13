import Foundation

// MARK: - Action Button Info (attached to a model)

/// Describes a single action button configured on a model.
/// Parsed from the `actions` array in the model JSON payload.
/// Example: `{"id": "generate_image", "name": "Generate Image", "description": "...", "icon": "data:image/svg+xml;base64,..."}`
struct AIModelAction: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    /// SVG icon as a data URI (`data:image/svg+xml;base64,...`) or an HTTP URL.
    let icon: String?

    init(id: String, name: String, description: String = "", icon: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? id
        self.description = json["description"] as? String ?? ""
        self.icon = json["icon"] as? String
    }
}

/// Metadata about an AI model available on an Iexa native server server.
struct AIModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String?
    var isMultimodal: Bool
    var supportsStreaming: Bool
    var supportsRAG: Bool
    var contextLength: Int?
    var capabilities: [String: String]?
    var profileImageURL: String?
    var toolIds: [String]
    /// Feature IDs that should be enabled by default for this model.
    /// Set by admin in the model editor (e.g., `["web_search", "image_generation"]`).
    var defaultFeatureIds: [String]
    /// The function calling mode configured for this model by the admin.
    /// Values: `"native"` for native tool calling, `nil`/absent for default (server-handled).
    /// Sourced from `info.params.function_calling` in the Iexa native server model payload.
    var functionCallingMode: String?
    /// Builtin tools enabled for this model by the admin.
    /// Keys match Iexa native server's `meta.builtinTools` object (e.g. `"memory"`, `"time"`,
    /// `"web_search"`, `"image_generation"`, `"code_interpreter"`, etc.).
    /// A `true` value means the tool is available; `false` means it's disabled.
    var builtinTools: [String: Bool]
    /// Tag names extracted from the server's `tags` array (e.g. `["OpenRou", "External"]`).
    /// Used to drive the tag-filter pills in the model selector sheet.
    var tags: [String]
    /// The connection type for this model (e.g. `"external"`, `"internal"`).
    /// Sourced from `connection_type` in the Iexa native server model payload.
    var connectionType: String?
    /// Whether this is a pipe/function model.
    /// Pipe models require `model_item` + `params`/`tool_servers`/`features`/`variables`
    /// to be sent unconditionally in every request — even when empty — so the backend
    /// pipe function can route the request correctly. Without these fields the backend
    /// hangs waiting for a Redis async task that never completes (~60s timeout).
    var isPipeModel: Bool
    /// Filter IDs associated with this model. Extracted from `filters[*].id` in the
    /// Iexa native server model payload. Sent as `filter_ids` in chat completion requests so
    /// the backend runs the correct filter pipeline for this model.
    var filterIds: [String]
    /// Raw action IDs from the model's `meta.actionIds` field. Used to resolve
    /// which action functions should show for this model when combined with
    /// global action function state.
    var actionIds: [String]
    /// Action buttons configured for this model. Parsed from `actions` array in
    /// the model payload or resolved from `actionIds` + global function state.
    /// Each entry describes a function-based action button (icon, name, description)
    /// that should appear in the assistant message action bar.
    var actions: [AIModelAction]
    /// Per-model suggestion prompts configured by the admin in the model editor.
    /// Per-model suggestion prompts shown on the welcome screen. Takes priority over
    /// admin-level `default_prompt_suggestions` from `/api/config` — admin config is
    /// used only as a fallback when the model has no suggestions of its own.
    /// Format matches `BackendConfig.PromptSuggestion`: `{"title": ["...", "..."], "content": "..."}`.
    var suggestionPrompts: [BackendConfig.PromptSuggestion]
    /// The full raw model JSON from the server. Sent as `model_item` in chat completion
    /// requests for pipe models so the backend can route to the correct pipe function.
    /// Stored as `[String: Any]` (non-Codable) and excluded from Codable synthesis.
    var rawModelItem: [String: Any]?

    init(
        id: String,
        name: String,
        description: String? = nil,
        isMultimodal: Bool = false,
        supportsStreaming: Bool = true,
        supportsRAG: Bool = false,
        contextLength: Int? = nil,
        capabilities: [String: String]? = nil,
        profileImageURL: String? = nil,
        toolIds: [String] = [],
        defaultFeatureIds: [String] = [],
        functionCallingMode: String? = nil,
        builtinTools: [String: Bool] = [:],
        tags: [String] = [],
        connectionType: String? = nil,
        isPipeModel: Bool = false,
        filterIds: [String] = [],
        actionIds: [String] = [],
        actions: [AIModelAction] = [],
        suggestionPrompts: [BackendConfig.PromptSuggestion] = [],
        rawModelItem: [String: Any]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isMultimodal = isMultimodal
        self.supportsStreaming = supportsStreaming
        self.supportsRAG = supportsRAG
        self.contextLength = contextLength
        self.capabilities = capabilities
        self.profileImageURL = profileImageURL
        self.toolIds = toolIds
        self.defaultFeatureIds = defaultFeatureIds
        self.functionCallingMode = functionCallingMode
        self.builtinTools = builtinTools
        self.tags = tags
        self.connectionType = connectionType
        self.isPipeModel = isPipeModel
        self.filterIds = filterIds
        self.actionIds = actionIds
        self.actions = actions
        self.suggestionPrompts = suggestionPrompts
        self.rawModelItem = rawModelItem
    }

    /// Whether the memory builtin tool is enabled for this model.
    var supportsMemory: Bool {
        builtinTools["memory"] == true
    }

    /// A short display name, extracting the model name after any provider prefix.
    var shortName: String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    /// Returns true when this model is likely to be an image generation model.
    /// Uses admin-provided capability metadata first, then name/tool heuristics
    /// as a fallback for models whose identifiers do not literally contain
    /// `gpt-image-2` or another single hardcoded name.
    var supportsImageGeneration: Bool {
        if LocalModelCapabilityRegistry.explicitlyDisablesImageGeneration(for: self) {
            return false
        }
        return resolvedCapabilities.supportsImageGeneration
    }

    var supportsImageInput: Bool {
        isMultimodal || resolvedCapabilities.supportsImageInput
    }

    var supportsImageOutput: Bool {
        resolvedCapabilities.supportsImageOutput
    }

    var supportsReasoning: Bool {
        resolvedCapabilities.supportsReasoning == true
    }

    var supportsVideoGeneration: Bool {
        resolvedCapabilities.supportsVideoGeneration
    }

    var supportsAudioOutput: Bool {
        resolvedCapabilities.supportsAudioOutput
    }

    var isCodeSpecialized: Bool {
        LocalModelCapabilityRegistry.isCodeModel(self)
    }

    var supportsToolCalling: Bool {
        resolvedCapabilities.supportsToolCalling == true || functionCallingMode == "native"
    }

    var supportsStructuredOutput: Bool {
        resolvedCapabilities.supportsStructuredOutput == true
    }

    var resolvedContextLength: Int? {
        LocalModelCapabilityRegistry.contextLength(for: self, modelId: id)
    }

    var declaredContextLength: Int? {
        LocalModelCapabilityRegistry.declaredContextLength(for: self)
    }

    var resolvedCapabilities: LocalModelCapability {
        LocalModelCapabilityRegistry.capability(for: self)
    }

    fileprivate static let imageGenerationHintTokens: [String] = [
        "image", "img", "dall-e", "dalle", "gpt-image", "imagen",
        "flux", "sdxl", "stable-diffusion", "midjourney", "mj-",
        "banana", "nano-banana", "grok-imagine", "grok imagine",
        "seedream", "qwen-image", "jimeng", "kolors", "minimax-image"
    ]

    fileprivate static let imageGenerationNegativeTokens: [String] = [
        "vision", "ocr", "vl", "video", "videos", "veo", "sora",
        "wan", "kling", "hailuo", "runway", "luma", "pika", "vidu",
        "seedance", "text-to-video", "image-to-video", "i2v", "t2v",
        "生视频", "视频生成"
    ]

    fileprivate static let imageInputHintTokens: [String] = [
        "vision", "multimodal", "image_input", "input_image", "image input",
        "images_input", "supports_image_input", "vlm"
    ]

    fileprivate static let videoGenerationHintTokens: [String] = [
        "video", "videos", "text-to-video", "image-to-video", "t2v", "i2v",
        "veo", "sora", "kling", "hailuo", "runway", "luma", "pika", "vidu",
        "seedance", "wan-", "wan_", "wan2", "minimax-video", "grok-imagine-video",
        "grok-imagine-video-1.5", "grok-imagine-video-1.5-preview",
        "grok-imagine-video-1.5-2026-05-30",
        "视频", "生视频", "视频生成"
    ]

    fileprivate static let reasoningHintTokens: [String] = [
        "reasoning", "reasoner", "thinking", "think", "deepseek-r1",
        "r1", "qwq", "o1", "o3", "o4", "grok-4", "grok-5"
    ]

    fileprivate static let audioHintTokens: [String] = [
        "audio", "voice", "speech", "tts", "stt", "whisper", "transcribe",
        "语音", "音频"
    ]

    fileprivate static let codeModelHintTokens: [String] = [
        "coder", "code", "coding", "codestral", "devstral", "qwen-coder",
        "deepseek-coder", "claude-code", "代码", "编程"
    ]

    // MARK: - Hashable & Equatable (rawModelItem excluded — [String: Any] is not Hashable)

    static func == (lhs: AIModel, rhs: AIModel) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isPipeModel == rhs.isPipeModel
            && lhs.filterIds == rhs.filterIds
            && lhs.functionCallingMode == rhs.functionCallingMode
            && lhs.toolIds == rhs.toolIds
            && lhs.defaultFeatureIds == rhs.defaultFeatureIds
            && lhs.capabilities == rhs.capabilities
            && lhs.builtinTools == rhs.builtinTools
            && lhs.tags == rhs.tags
            && lhs.actions == rhs.actions
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(isPipeModel)
        hasher.combine(filterIds)
    }

    // MARK: - Codable (rawModelItem excluded — [String: Any] is not Codable)

    enum CodingKeys: String, CodingKey {
        case id, name, description, isMultimodal, supportsStreaming, supportsRAG
        case contextLength, capabilities, profileImageURL, toolIds, defaultFeatureIds
        case functionCallingMode, builtinTools, tags, connectionType, isPipeModel, filterIds, actionIds, actions, suggestionPrompts
        // rawModelItem is intentionally excluded from Codable — it contains
        // [String: Any] which cannot be synthesised. It is populated at runtime
        // from the live model fetch and does not need persistence.
    }

    // MARK: - Avatar URL Resolution

    /// Resolves the avatar URL for this model.
    ///
    /// Always uses the server's per-model endpoint `/api/v1/models/model/profile/image?id=X`.
    /// The server returns the model's custom avatar if one is set, or the default favicon
    /// for models without one. Results are cached by `ImageCacheService` so subsequent
    /// opens of the model picker are instant with zero network requests.
    ///
    /// External HTTP/HTTPS `profileImageURL` values (e.g. OAuth avatars) are used directly.
    func resolveAvatarURL(baseURL: String) -> URL? {
        // External HTTP/HTTPS URL — use directly.
        if let raw = profileImageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        // All other cases (nil, empty, data URI, relative path like "/static/favicon.png"):
        // delegate to the per-model endpoint. The server knows whether this model has a
        // custom avatar and returns the right image — no client-side guessing needed.
        return buildModelAvatarURL(baseURL: baseURL)
    }

    /// Builds the model avatar URL using the Iexa native server endpoint:
    /// `/api/v1/models/model/profile/image?id={modelId}`
    ///
    /// This endpoint requires authentication (handled by ``AuthenticatedImageView``
    /// or by appending the auth token as a query parameter / header).
    private func buildModelAvatarURL(baseURL: String) -> URL? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !id.isEmpty else { return nil }

        let normalizedBase = trimmedBase.hasSuffix("/")
            ? String(trimmedBase.dropLast())
            : trimmedBase

        var components = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        return components?.url
    }
}

struct LocalModelCapability: Hashable, Sendable {
    var inputModalities: Set<String> = ["text"]
    var outputModalities: Set<String> = ["text"]
    var endpointTypes: Set<String> = []
    var contextLength: Int?
    var supportsToolCalling: Bool?
    var supportsReasoning: Bool?
    var supportsStructuredOutput: Bool?

    var supportsImageInput: Bool {
        inputModalities.contains("image") || inputModalities.contains("vision")
    }

    var supportsImageOutput: Bool {
        outputModalities.contains("image")
            || endpointTypes.contains("images")
            || endpointTypes.contains("image_generation")
    }

    var supportsImageGeneration: Bool {
        supportsImageOutput
            || endpointTypes.contains("image")
            || endpointTypes.contains("image_generations")
    }

    var supportsVideoGeneration: Bool {
        outputModalities.contains("video")
            || endpointTypes.contains("video")
            || endpointTypes.contains("videos")
            || endpointTypes.contains("video_generation")
            || endpointTypes.contains("video_generations")
    }

    var supportsAudioOutput: Bool {
        outputModalities.contains("audio")
            || outputModalities.contains("speech")
            || endpointTypes.contains("audio")
            || endpointTypes.contains("audio_generation")
            || endpointTypes.contains("tts")
    }
}

enum LocalModelCapabilityRegistry {
    static func explicitlyDisablesImageGeneration(for model: AIModel) -> Bool {
        if let value = model.capabilities?["image_generation"],
           truthy(value) == false {
            return true
        }
        return false
    }

    static func capability(for model: AIModel) -> LocalModelCapability {
        var capability = LocalModelCapability()
        capability.contextLength = contextLength(for: model, modelId: model.id)

        if model.isMultimodal {
            capability.inputModalities.insert("image")
        }
        if model.defaultFeatureIds.contains("image_generation")
            || model.builtinTools["image_generation"] == true {
            capability.outputModalities.insert("image")
            capability.endpointTypes.insert("image_generation")
        }
        if model.functionCallingMode == "native" || !model.toolIds.isEmpty {
            capability.supportsToolCalling = true
        }

        applyCapabilities(model.capabilities, to: &capability)
        scanRawModelItem(model.rawModelItem, into: &capability)

        let haystack = searchableText(for: model)
        if AIModel.imageGenerationHintTokens.contains(where: { haystack.contains($0) })
            && !AIModel.imageGenerationNegativeTokens.contains(where: { haystack.contains($0) }) {
            capability.outputModalities.insert("image")
            capability.endpointTypes.insert("image_generation")
        }
        if AIModel.imageInputHintTokens.contains(where: { haystack.contains($0) }) {
            capability.inputModalities.insert("image")
        }
        if AIModel.videoGenerationHintTokens.contains(where: { haystack.contains($0) }) {
            capability.outputModalities.insert("video")
            capability.endpointTypes.insert("video_generation")
        }
        if AIModel.audioHintTokens.contains(where: { haystack.contains($0) }) {
            capability.outputModalities.insert("audio")
        }
        if AIModel.reasoningHintTokens.contains(where: { haystack.contains($0) }) {
            capability.supportsReasoning = true
        }
        return capability
    }

    static func isCodeModel(_ model: AIModel) -> Bool {
        let haystack = searchableText(for: model)
        return AIModel.codeModelHintTokens.contains { haystack.contains($0) }
    }

    static func contextLength(for model: AIModel?, modelId: String?) -> Int? {
        if let declared = declaredContextLength(for: model) {
            return declared
        }

        var parts: [String] = []
        if let modelId, !modelId.isEmpty { parts.append(modelId) }
        if let model {
            parts.append(model.id)
            parts.append(model.name)
            if let description = model.description, !description.isEmpty {
                parts.append(description)
            }
        }
        let raw = parts.joined(separator: " ").lowercased()
        if raw.contains("1m") || raw.contains("1000k") { return 1_000_000 }
        if raw.contains("512k") { return 512_000 }
        if raw.contains("256k") { return 256_000 }
        if raw.contains("200k") { return 200_000 }
        if raw.contains("128k") { return 128_000 }
        if raw.contains("96k") { return 96_000 }
        if raw.contains("64k") { return 64_000 }
        if raw.contains("32k") { return 32_000 }
        if raw.contains("16k") { return 16_000 }
        if raw.contains("8k") { return 8_000 }
        if raw.contains("4k") { return 4_000 }
        if raw.contains("claude-3") || raw.contains("claude-sonnet") || raw.contains("claude-opus") {
            return 200_000
        }
        if raw.contains("gemini-1.5") || raw.contains("gemini-2") {
            return 1_000_000
        }
        if raw.contains("gpt-4.1") || raw.contains("gpt-5") || raw.contains("gpt-4o") || raw.contains("o3") || raw.contains("o4") {
            return 128_000
        }
        if raw.contains("qwen") || raw.contains("grok") || raw.contains("deepseek") {
            return 128_000
        }
        return nil
    }

    static func declaredContextLength(for model: AIModel?) -> Int? {
        if let explicit = model?.contextLength, explicit > 0 {
            return explicit
        }
        if let rawContext = scanContextLength(in: model?.rawModelItem), rawContext > 0 {
            return rawContext
        }
        return nil
    }

    private static func applyCapabilities(_ capabilities: [String: String]?, to capability: inout LocalModelCapability) {
        guard let capabilities else { return }
        for (key, value) in capabilities {
            applyCapabilityValue(key: key, value: value, to: &capability)
        }
    }

    private static func scanRawModelItem(_ raw: [String: Any]?, into capability: inout LocalModelCapability) {
        guard let raw else { return }
        scanDictionary(raw, into: &capability, depth: 0)
    }

    private static func scanDictionary(_ dict: [String: Any], into capability: inout LocalModelCapability, depth: Int) {
        guard depth <= 4 else { return }
        for (key, value) in dict {
            let normalizedKey = normalizeToken(key)
            if ["input_modalities", "inputmodalities", "inputs", "modalities_input"].contains(normalizedKey) {
                addModalities(from: value, to: &capability.inputModalities)
            } else if ["output_modalities", "outputmodalities", "outputs", "modalities_output"].contains(normalizedKey) {
                addModalities(from: value, to: &capability.outputModalities)
            } else if ["modalities", "supported_modalities", "supportedmodalities"].contains(normalizedKey) {
                addModalities(from: value, to: &capability.inputModalities)
                addModalities(from: value, to: &capability.outputModalities)
            } else if ["supported_endpoint_types", "supportedendpoints", "endpoint_types", "endpoints"].contains(normalizedKey) {
                addModalities(from: value, to: &capability.endpointTypes)
            } else {
                applyCapabilityValue(key: key, value: value, to: &capability)
            }

            if let nested = value as? [String: Any] {
                scanDictionary(nested, into: &capability, depth: depth + 1)
            } else if let nestedArray = value as? [[String: Any]] {
                for nested in nestedArray.prefix(12) {
                    scanDictionary(nested, into: &capability, depth: depth + 1)
                }
            }
        }
    }

    private static func applyCapabilityValue(key: String, value: Any, to capability: inout LocalModelCapability) {
        let normalizedKey = normalizeToken(key)
        let truth = truthy(value)
        switch normalizedKey {
        case "image_generation", "imagegeneration", "image_output", "imageoutput", "output_image", "outputimage", "images":
            if truth != false {
                capability.outputModalities.insert("image")
                capability.endpointTypes.insert("image_generation")
            }
        case "vision", "image_input", "imageinput", "input_image", "inputimage", "images_input", "imagesinput", "supports_image_input", "supportsimageinput", "multimodal":
            if truth != false {
                capability.inputModalities.insert("image")
            }
        case "tool_calling", "toolcalling", "tool_calls", "toolcalls", "function_calling", "functioncalling":
            if let truth { capability.supportsToolCalling = truth }
        case "reasoning", "thinking":
            if let truth { capability.supportsReasoning = truth }
        case "structured_output", "structuredoutput", "structured_outputs", "structuredoutputs", "json_schema", "jsonschema":
            if let truth { capability.supportsStructuredOutput = truth }
        case "interleaved":
            if let field = (value as? [String: Any])?["field"] as? String,
               !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                capability.supportsReasoning = true
            }
        case "audio_output", "audiooutput", "audio_generation", "audiogeneration", "tts", "speech":
            if truth != false {
                capability.outputModalities.insert("audio")
                capability.endpointTypes.insert("audio_generation")
            }
        case "video_output", "videooutput", "video_generation", "videogeneration", "video_generations", "videogenerations", "videos", "text_to_video", "texttovideo", "image_to_video", "imagetovideo":
            if truth != false {
                capability.outputModalities.insert("video")
                capability.endpointTypes.insert("video_generation")
            }
        default:
            break
        }
        if capability.contextLength == nil, let context = intValue(value), normalizedKey.contains("context") {
            capability.contextLength = context
        }
    }

    private static func scanContextLength(in raw: [String: Any]?) -> Int? {
        guard let raw else { return nil }
        return scanContextLength(in: raw, depth: 0)
    }

    private static func scanContextLength(in dict: [String: Any], depth: Int) -> Int? {
        guard depth <= 4 else { return nil }
        let keys = [
            "context",
            "context_length", "contextLength", "context_window", "contextWindow",
            "max_context_length", "maxContextLength", "max_context", "maxContext",
            "num_ctx", "n_ctx", "ctx", "context_size", "contextSize",
            "max_input_tokens", "maxInputTokens", "input_token_limit", "inputTokenLimit",
            "prompt_token_limit", "promptTokenLimit", "token_limit", "tokenLimit",
            "max_model_len", "maxModelLen", "model_max_length", "modelMaxLength",
            "max_sequence_length", "maxSequenceLength", "max_position_embeddings", "maxPositionEmbeddings"
        ]
        for key in keys {
            if let value = intValue(dict[key]) {
                return value
            }
        }
        for value in dict.values {
            if let nested = value as? [String: Any],
               let context = scanContextLength(in: nested, depth: depth + 1) {
                return context
            } else if let nestedArray = value as? [[String: Any]] {
                for nested in nestedArray.prefix(12) {
                    if let context = scanContextLength(in: nested, depth: depth + 1) {
                        return context
                    }
                }
            }
        }
        return nil
    }

    private static func addModalities(from value: Any, to set: inout Set<String>) {
        for item in stringValues(value) {
            let normalized = normalizeToken(item)
            if normalized == "images" || normalized.contains("image_generation") || normalized.contains("imagegeneration") {
                set.insert("image_generation")
            } else if normalized.contains("image") || normalized == "vision" {
                set.insert("image")
            } else if normalized.contains("audio") {
                set.insert("audio")
            } else if normalized.contains("video") {
                set.insert("video")
            } else if normalized.contains("text") {
                set.insert("text")
            } else if !normalized.isEmpty {
                set.insert(normalized)
            }
        }
    }

    private nonisolated static func stringValues(_ value: Any) -> [String] {
        if let string = value as? String {
            return string
                .split { $0 == "," || $0.isWhitespace }
                .map(String.init)
        }
        if let strings = value as? [String] { return strings }
        if let array = value as? [Any] { return array.flatMap(stringValues) }
        if let dict = value as? [String: Any] {
            return dict.flatMap { key, value in [key] + stringValues(value) }
        }
        return []
    }

    private static func truthy(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let double = value as? Double { return double != 0 }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let string = value as? String {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "enabled", "on", "supported"].contains(cleaned) { return true }
            if ["0", "false", "no", "disabled", "off", "unsupported"].contains(cleaned) { return false }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int, int > 0 { return int }
        if let double = value as? Double, double > 0 { return Int(double) }
        if let number = value as? NSNumber, number.intValue > 0 { return number.intValue }
        if let string = value as? String {
            let cleaned = string
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if cleaned.hasSuffix("k"), let n = Double(cleaned.dropLast()) {
                return Int(n * 1_000)
            }
            if cleaned.hasSuffix("m"), let n = Double(cleaned.dropLast()) {
                return Int(n * 1_000_000)
            }
            if let int = Int(cleaned), int > 0 { return int }
        }
        return nil
    }

    private static func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    private static func searchableText(for model: AIModel) -> String {
        var parts = [model.id, model.name, model.description ?? "", model.connectionType ?? ""]
        parts.append(contentsOf: model.tags)
        parts.append(contentsOf: model.toolIds)
        parts.append(contentsOf: model.defaultFeatureIds)
        parts.append(contentsOf: model.actionIds)
        parts.append(contentsOf: model.actions.map(\.id))
        parts.append(contentsOf: model.actions.map(\.name))
        if let capabilities = model.capabilities {
            parts.append(contentsOf: capabilities.keys)
            parts.append(contentsOf: capabilities.values)
        }
        return parts.joined(separator: " ").lowercased()
    }
}
