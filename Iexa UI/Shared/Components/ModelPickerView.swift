import SwiftUI

private struct ModelPickerCapabilityBadge: Hashable {
    let icon: String
    let text: String
}

private func modelPickerCapabilityBadges(for model: AIModel) -> [ModelPickerCapabilityBadge] {
    var badges: [ModelPickerCapabilityBadge] = []
    if let context = model.resolvedContextLength, context > 0 {
        let text: String
        if context >= 1_000_000 {
            text = "\(context / 1_000_000)M"
        } else if context >= 1_000 {
            text = "\(context / 1_000)K"
        } else {
            text = "\(context)"
        }
        badges.append(ModelPickerCapabilityBadge(icon: "rectangle.expand.vertical", text: text))
    }
    if model.supportsImageGeneration {
        badges.append(ModelPickerCapabilityBadge(icon: "photo.on.rectangle.angled", text: "生图"))
    } else if model.supportsImageInput {
        badges.append(ModelPickerCapabilityBadge(icon: "eye", text: "视觉"))
    }
    if model.supportsReasoning {
        badges.append(ModelPickerCapabilityBadge(icon: "brain.head.profile", text: "推理"))
    }
    if model.supportsToolCalling {
        badges.append(ModelPickerCapabilityBadge(icon: "wrench.and.screwdriver", text: "工具"))
    }
    if model.supportsStructuredOutput {
        badges.append(ModelPickerCapabilityBadge(icon: "curlybraces.square", text: "JSON"))
    }
    return badges
}

// MARK: - Model Picker View

/// A floating popup that appears above the chat input when the user types `@`.
///
/// Shows available AI models filtered by the text typed after `@`.
/// Mirrors the design of `KnowledgePickerView` for visual consistency.
struct ModelPickerView: View {
    let query: String
    let models: [AIModel]
    let serverBaseURL: String
    let authToken: String?
    let keyboardHeight: CGFloat
    let onSelect: (AIModel) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    private var availableHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen.bounds.height
            ?? UIScreen.main.bounds.height
        let topSafeArea = scene?.windows.first?.safeAreaInsets.top ?? 59
        let bottomSafeArea = scene?.windows.first?.safeAreaInsets.bottom ?? 34
        let reserved = topSafeArea + 44 + 16
        let usable = screen - reserved - keyboardHeight - bottomSafeArea - 56
        return max(120, usable)
    }

    // MARK: - Filtered Models

    private var filteredModels: [AIModel] {
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.shortName.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if models.isEmpty {
                loadingView
            } else if filteredModels.isEmpty {
                emptyView
            } else {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: availableHeight)
        .background(pickerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(
            color: theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.12),
            radius: 16, x: 0, y: -4
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Background

    private var pickerBackground: some View {
        Group {
            if theme.isDark {
                theme.cardBackground.opacity(0.98)
            } else {
                Color(.systemBackground).opacity(0.98)
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading models…")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 24)
                .foregroundStyle(theme.textTertiary)
            Text("No models match \"\(query)\"")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader("Models")
                ForEach(filteredModels) { model in
                    modelRow(model)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 11, weight: .semibold)
            .textCase(.uppercase)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    // MARK: - Model Row

    private func modelRow(_ model: AIModel) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(model)
        } label: {
            HStack(spacing: 12) {
                // Avatar
                ModelAvatar(
                    size: 36,
                    imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                    label: model.shortName,
                    authToken: authToken
                )

                // Name + badges + description
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.shortName)
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        if model.functionCallingMode == "native" {
                            HStack(spacing: 3) {
                                Image(systemName: "bolt.fill")
                                    .scaledFont(size: 8, weight: .bold)
                                Text("Native")
                                    .scaledFont(size: 10, weight: .semibold)
                            }
                                .foregroundStyle(theme.brandPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.brandPrimary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    if let desc = model.description, !desc.isEmpty {
                        Text(desc)
                            .scaledFont(size: 12, weight: .regular)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }

                    modelCapabilityRow(model)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModelRowButtonStyle(theme: theme))
    }

    @ViewBuilder
    private func modelCapabilityRow(_ model: AIModel) -> some View {
        let badges = modelPickerCapabilityBadges(for: model)
        if !badges.isEmpty {
            HStack(spacing: 8) {
                ForEach(badges, id: \.self) { badge in
                    HStack(spacing: 3) {
                        Image(systemName: badge.icon)
                            .scaledFont(size: 9, weight: .medium)
                        Text(badge.text)
                            .scaledFont(size: 10, weight: .medium)
                    }
                    .foregroundStyle(theme.textTertiary)
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - Row Button Style

private struct ModelRowButtonStyle: ButtonStyle {
    let theme: AppTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.brandPrimary.opacity(0.08)
                    : Color.clear
            )
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
