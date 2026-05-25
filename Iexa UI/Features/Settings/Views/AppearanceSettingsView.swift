import SwiftUI

/// Settings screen for appearance preferences: color scheme, accent color, theme options.
struct AppearanceSettingsView: View {
    @Bindable var manager: AppearanceManager
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewColorScheme: ColorScheme?
    @State private var showColorWheel = false
    @State private var wheelColor: Color = .blue
    @Namespace private var accentAnimation
    @AppStorage("streamingBlurAnimation") private var streamingBlurEnabled: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // Live Preview Card
                themePreviewCard

                // Color Scheme
                SettingsSection(
                    header: "外观",
                    footer: "选择 Iexa 的显示方式。“跟随系统”会使用设备当前设置。"
                ) {
                    colorSchemePicker
                }

                // Accent Color
                SettingsSection(
                    header: "强调色",
                    footer: "用于按钮、链接和交互元素。点选色轮可以选择任意自定义颜色。"
                ) {
                    accentColorGrid
                        .padding(Spacing.md)
                }

                // Theme Options
                SettingsSection(header: "主题选项") {
                    SettingsCell(
                        icon: "moon.stars.fill",
                        title: "纯黑深色模式",
                        subtitle: "使用更适合 OLED 屏幕的纯黑背景",
                        accessory: .toggle(
                            isOn: manager.usePureBlackDark,
                            onChange: { manager.usePureBlackDark = $0 }
                        )
                    )

                    SettingsCell(
                        icon: "paintpalette.fill",
                        title: "背景染色",
                        subtitle: "给背景加入轻微的强调色氛围",
                        accessory: .toggle(
                            isOn: manager.useTintedBackgrounds,
                            onChange: { manager.useTintedBackgrounds = $0 }
                        )
                    )

                }

            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Live Preview Card

    private var themePreviewCard: some View {
        VStack(spacing: 0) {
            // Mini chat preview
            VStack(spacing: Spacing.sm) {
                // Simulated assistant message
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Circle()
                        .fill(theme.accentTint)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "sparkles")
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(theme.accentColor)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 助手")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)

                        Text("这是当前主题的预览效果。试试不同强调色，找到最顺眼的风格。")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.chatBubbleAssistantText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(theme.chatBubbleAssistant)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(theme.chatBubbleAssistantBorder, lineWidth: 0.5)
                            )
                    }

                    Spacer(minLength: 40)
                }

                // Simulated user message
                HStack {
                    Spacer(minLength: 60)

                    Text("看起来不错")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.chatBubbleUserText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.chatBubbleUser)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Simulated input bar
                HStack(spacing: Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .scaledFont(size: 18)
                            .foregroundStyle(theme.textTertiary)

                        Text("发送消息")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.inputPlaceholder)

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(theme.inputBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(theme.inputBorder, lineWidth: 0.5)
                    )

                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "arrow.up")
                                .scaledFont(size: 14, weight: .bold)
                                .foregroundStyle(theme.onAccentColor)
                        }
                }
                .padding(.top, 4)
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
        .animation(.easeInOut(duration: AnimDuration.fast), value: manager.accentColorPreset)
        .animation(.easeInOut(duration: AnimDuration.fast), value: manager.useTintedBackgrounds)
        .animation(.easeInOut(duration: AnimDuration.fast), value: manager.usePureBlackDark)
    }

    // MARK: - Color Scheme Picker

    private var colorSchemePicker: some View {
        HStack(spacing: 0) {
            ForEach(AppearanceManager.ColorSchemeMode.allCases, id: \.self) { mode in
                let isSelected = manager.colorSchemeMode == mode

                Button {
                    withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                        manager.colorSchemeMode = mode
                    }
                    Haptics.play(.light)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .scaledFont(size: 18, weight: .medium)
                            .foregroundStyle(isSelected ? theme.accentColor : theme.textTertiary)
                            .frame(height: 24)

                        Text(mode.displayName)
                            .scaledFont(size: 12, weight: isSelected ? .semibold : .medium)
                            .foregroundStyle(isSelected ? theme.textPrimary : theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.accentTint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.displayName)主题")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
    }

    // MARK: - Accent Color Grid

    private var accentColorGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: 4
            ),
            spacing: 16
        ) {
            ForEach(AppearanceManager.AccentColorPreset.allCases, id: \.self) { preset in
                accentColorCell(preset)
            }

            // Color wheel cell — last item in the grid
            colorWheelCell
        }
        .sheet(isPresented: $showColorWheel) {
            colorWheelSheet
        }
    }

    // MARK: - Color Wheel Grid Cell

    private var colorWheelCell: some View {
        let isSelected = manager.useCustomColor

        return Button {
            wheelColor = manager.useCustomColor ? manager.customColor : manager.accentColorPreset.resolved(for: colorScheme)
            showColorWheel = true
            Haptics.play(.light)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    // Outer ring when custom color is selected
                    Circle()
                        .strokeBorder(
                            isSelected ? manager.customColor : Color.clear,
                            lineWidth: isSelected ? 2.5 : 0
                        )
                        .frame(width: 44, height: 44)
                        .opacity(isSelected ? 1 : 0)

                    // Rainbow wheel circle
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(hue: 0.0, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 0.15, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 0.3, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 0.45, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 0.6, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 0.75, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 0.9, saturation: 0.75, brightness: 0.9),
                                    Color(hue: 1.0, saturation: 0.75, brightness: 0.9),
                                ]),
                                center: .center
                            )
                        )
                        .frame(width: isSelected ? 32 : 38, height: isSelected ? 32 : 38)
                        .shadow(
                            color: Color.purple.opacity(isSelected ? 0.4 : 0.15),
                            radius: isSelected ? 6 : 2,
                            y: isSelected ? 3 : 1
                        )
                        .overlay {
                            if isSelected {
                                // Show the selected custom color dot in the center
                                Circle()
                                    .fill(manager.customColor)
                                    .frame(width: 16, height: 16)
                                    .shadow(color: manager.customColor.opacity(0.5), radius: 3, y: 1)
                            }
                        }
                }
                .frame(width: 48, height: 48)

                Text("自定义")
                    .scaledFont(size: 10, weight: isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自定义颜色选择器")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accentColorCell(_ preset: AppearanceManager.AccentColorPreset) -> some View {
        let isSelected = manager.accentColorPreset == preset && !manager.useCustomColor
        let displayColor = preset.resolved(for: colorScheme)

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                manager.accentColorPreset = preset
                manager.useCustomColor = false
            }
            Haptics.play(.light)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    // Outer ring when selected
                    Circle()
                        .strokeBorder(displayColor, lineWidth: isSelected ? 2.5 : 0)
                        .frame(width: 44, height: 44)
                        .opacity(isSelected ? 1 : 0)

                    // Main color circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    displayColor,
                                    displayColor.opacity(0.8)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: isSelected ? 32 : 38, height: isSelected ? 32 : 38)
                        .shadow(
                            color: displayColor.opacity(isSelected ? 0.4 : 0.15),
                            radius: isSelected ? 6 : 2,
                            y: isSelected ? 3 : 1
                        )

                    // Checkmark
                    if isSelected {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(preset.resolvedOnAccent(for: colorScheme))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 48, height: 48)

                Text(preset.displayName)
                    .scaledFont(size: 10, weight: isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.displayName)强调色")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Color Wheel Sheet

    private var colorWheelSheet: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                Spacer()

                // Color picker
                ColorPicker("", selection: $wheelColor, supportsOpacity: false)
                    .labelsHidden()
                    .scaleEffect(2.0)
                    .frame(width: 60, height: 60)
                    .padding(40)

                // Preview of selected color
                VStack(spacing: Spacing.sm) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(wheelColor)
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: wheelColor.opacity(0.3), radius: 12, y: 4)

                    Text("预览")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, Spacing.screenPadding * 2)

                // Sample buttons with chosen color
                HStack(spacing: Spacing.md) {
                    // Primary button preview
                    Text("主按钮")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(wheelColor))

                    // Tinted button preview
                    Text("浅色按钮")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(wheelColor)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(wheelColor.opacity(0.15))
                        )
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(theme.background)
            .navigationTitle("选择颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showColorWheel = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            manager.setCustomColor(wheelColor)
                        }
                        showColorWheel = false
                        Haptics.play(.medium)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
