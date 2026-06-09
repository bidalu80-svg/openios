import SwiftUI

struct ModelCapabilityBadge: Hashable {
    let icon: String
    let text: String
}

func modelCapabilityBadges(for model: AIModel) -> [ModelCapabilityBadge] {
    var badges: [ModelCapabilityBadge] = []
    if let context = model.declaredContextLength, context > 0 {
        badges.append(ModelCapabilityBadge(icon: "rectangle.expand.vertical", text: formattedModelContext(context)))
    }

    var hasPrimaryCapability = false
    if model.supportsVideoGeneration {
        badges.append(ModelCapabilityBadge(icon: "film", text: "视频"))
        hasPrimaryCapability = true
    }
    if model.supportsImageGeneration {
        badges.append(ModelCapabilityBadge(icon: "photo.on.rectangle.angled", text: "生图"))
        hasPrimaryCapability = true
    } else if model.supportsImageInput {
        badges.append(ModelCapabilityBadge(icon: "eye", text: "视觉"))
        hasPrimaryCapability = true
    }
    if model.supportsAudioOutput {
        badges.append(ModelCapabilityBadge(icon: "waveform", text: "语音"))
        hasPrimaryCapability = true
    }
    if model.supportsReasoning {
        badges.append(ModelCapabilityBadge(icon: "brain.head.profile", text: "推理"))
        hasPrimaryCapability = true
    }
    if model.isCodeSpecialized {
        badges.append(ModelCapabilityBadge(icon: "chevron.left.forwardslash.chevron.right", text: "代码"))
        hasPrimaryCapability = true
    }
    if !hasPrimaryCapability {
        badges.append(ModelCapabilityBadge(icon: "bubble.left.and.bubble.right", text: "对话"))
    }
    if model.supportsToolCalling {
        badges.append(ModelCapabilityBadge(icon: "wrench.and.screwdriver", text: "工具"))
    }
    if model.supportsStructuredOutput {
        badges.append(ModelCapabilityBadge(icon: "curlybraces.square", text: "JSON"))
    }
    return badges
}

private func formattedModelContext(_ context: Int) -> String {
    if context >= 1_000_000 {
        return "\(context / 1_000_000)M"
    }
    if context >= 1_000 {
        return "\(context / 1_000)K"
    }
    return "\(context)"
}
