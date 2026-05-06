import SwiftUI

/// Settings screen for accessibility preferences: text scaling, UI scaling, and presets.
struct AccessibilitySettingsView: View {
    @Bindable var manager: AccessibilityManager
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // Live Preview Card
                livePreviewCard

                // Quick Presets
                SettingsSection(
                    header: "快速预设",
                    footer: "选择预设可以一次性调整所有缩放比例。"
                ) {
                    presetsRow
                        .padding(Spacing.md)
                }

                // Content Text Scale
                SettingsSection(
                    header: "消息文字",
                    footer: "调整聊天消息、Markdown 内容和笔记正文的字号。"
                ) {
                    scaleSlider(
                        value: Binding(
                            get: { manager.contentTextScale },
                            set: { manager.contentTextScale = $0 }
                        ),
                        range: AccessibilityManager.contentScaleRange,
                        icon: "text.bubble",
                        label: "内容文字"
                    )
                    .padding(Spacing.md)
                }

                // List Text Scale
                SettingsSection(
                    header: "标题与列表",
                    footer: "调整对话标题、文件夹名称和列表项目的字号。"
                ) {
                    scaleSlider(
                        value: Binding(
                            get: { manager.listTextScale },
                            set: { manager.listTextScale = $0 }
                        ),
                        range: AccessibilityManager.listScaleRange,
                        icon: "list.bullet",
                        label: "列表文字"
                    )
                    .padding(Spacing.md)
                }

                // UI Scale
                SettingsSection(
                    header: "界面缩放",
                    footer: "调整整个 App 中按钮、图标、间距和可点击区域的大小。"
                ) {
                    scaleSlider(
                        value: Binding(
                            get: { manager.uiScale },
                            set: { manager.uiScale = $0 }
                        ),
                        range: AccessibilityManager.uiScaleRange,
                        icon: "square.resize",
                        label: "界面"
                    )
                    .padding(Spacing.md)
                }

                // Reset
                if manager.isCustomized {
                    SettingsSection {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                manager.resetToDefaults()
                            }
                            Haptics.play(.medium)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 14, weight: .medium))
                                Text("恢复默认")
                                    .font(AppTypography.labelMediumFont)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.error)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.sm)
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("辅助功能")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Live Preview Card

    private var livePreviewCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.sm) {
                // Sample conversation title row (list context)
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(theme.brandPrimary.opacity(0.2))
                        .frame(
                            width: 32 * manager.uiScale,
                            height: 32 * manager.uiScale
                        )
                        .overlay(
                            Image(systemName: "brain")
                                .font(.system(size: 14 * manager.uiScale, weight: .medium))
                                .foregroundStyle(theme.brandPrimary)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("东京旅行计划")
                            .font(.system(size: 14 * manager.listTextScale, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text("帮我规划一周旅行…")
                            .font(.system(size: 12 * manager.listTextScale, weight: .regular))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("2 分钟前")
                        .font(.system(size: 10 * manager.uiScale, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.bottom, 4)

                Rectangle()
                    .fill(theme.divider)
                    .frame(height: 0.5)

                // Sample assistant message (content context)
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Circle()
                        .fill(theme.accentTint)
                        .frame(
                            width: 24 * manager.uiScale,
                            height: 24 * manager.uiScale
                        )
                        .overlay {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10 * manager.uiScale, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("助手")
                            .font(.system(size: 10 * manager.uiScale, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)

                        Text("这是东京 7 日行程建议！第 1 天可以逛涩谷和原宿。")
                            .font(.system(size: 15 * manager.contentTextScale, weight: .regular))
                            .foregroundStyle(theme.chatBubbleAssistantText)
                            .lineSpacing(2 * manager.contentTextScale)
                    }

                    Spacer(minLength: 20)
                }

                // Sample user message
                HStack {
                    Spacer(minLength: 40)

                    Text("预算方面有什么建议？")
                        .font(.system(size: 15 * manager.contentTextScale, weight: .regular))
                        .foregroundStyle(theme.chatBubbleUserText)
                        .padding(.horizontal, 12 * manager.uiScale)
                        .padding(.vertical, 8 * manager.uiScale)
                        .background(theme.chatBubbleUser)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Sample action buttons (UI context)
                HStack(spacing: 8 * manager.uiScale) {
                    ForEach(["doc.on.doc", "arrow.clockwise", "speaker.wave.2"], id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.system(size: 12 * manager.uiScale, weight: .medium))
                            .foregroundStyle(theme.textTertiary.opacity(0.7))
                            .frame(
                                width: 28 * manager.uiScale,
                                height: 28 * manager.uiScale
                            )
                    }
                    Spacer()
                }
            }
            .padding(Spacing.md)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 1)
            )
        }
        .padding(.horizontal, Spacing.screenPadding)
        .animation(.easeInOut(duration: 0.2), value: manager.contentTextScale)
        .animation(.easeInOut(duration: 0.2), value: manager.listTextScale)
        .animation(.easeInOut(duration: 0.2), value: manager.uiScale)
    }

    // MARK: - Presets Row

    private var presetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(AccessibilityManager.Preset.allCases) { preset in
                    let isSelected = manager.matchingPreset == preset

                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            manager.apply(preset: preset)
                        }
                        Haptics.play(.light)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(isSelected ? theme.accentColor : theme.textSecondary)

                            Text(preset.displayName)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? theme.textPrimary : theme.textTertiary)
                        }
                        .frame(width: 72, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? theme.accentTint : theme.surfaceContainer.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isSelected ? theme.accentColor.opacity(0.4) : theme.cardBorder.opacity(0.3),
                                    lineWidth: isSelected ? 1.5 : 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.displayName)预设")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Scale Slider

    private func scaleSlider(
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        icon: String,
        label: String
    ) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: 28)

                Text(label)
                    .font(AppTypography.labelMediumFont)
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                Text("\(Int(round(value.wrappedValue * 100)))%")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.brandPrimary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            Slider(value: value, in: range, step: 0.05) {
                Text(label)
            } minimumValueLabel: {
                Text("A")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            } maximumValueLabel: {
                Text("A")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            .tint(theme.brandPrimary)
            .onChange(of: value.wrappedValue) { _, _ in
                Haptics.play(.light)
            }

            // Scale indicator bar
            HStack(spacing: 0) {
                ForEach([0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5], id: \.self) { tick in
                    if tick >= range.lowerBound && tick <= range.upperBound {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(
                                    abs(value.wrappedValue - tick) < 0.03
                                        ? theme.brandPrimary
                                        : theme.textTertiary.opacity(0.3)
                                )
                                .frame(width: 4, height: 4)
                            if tick == 1.0 {
                                Text("默认")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
