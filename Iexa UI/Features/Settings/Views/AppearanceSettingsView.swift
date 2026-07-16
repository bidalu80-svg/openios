import SwiftUI
import PhotosUI
import UIKit

/// Settings screen for appearance preferences: color scheme, accent color, theme options.
struct AppearanceSettingsView: View {
    @Bindable var manager: AppearanceManager
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewColorScheme: ColorScheme?
    @State private var showColorWheel = false
    @State private var wheelColor: Color = .blue
    @State private var selectedChatBackgroundItem: PhotosPickerItem?
    @State private var pendingChatBackgroundData: Data?
    @State private var pendingChatBackgroundImage: UIImage?
    @State private var showChatBackgroundPreview = false
    @State private var isLoadingChatBackground = false
    @State private var chatBackgroundErrorMessage: String?
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

                chatBackgroundSettingsSection

            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedChatBackgroundItem) { _, item in
            Task { await loadChatBackgroundPreview(from: item) }
        }
        .sheet(isPresented: $showChatBackgroundPreview) {
            if let image = pendingChatBackgroundImage,
               let data = pendingChatBackgroundData {
                ChatBackgroundPreviewSheet(
                    image: image,
                    imageData: data,
                    manager: manager
                )
            }
        }
        .alert("无法使用这张图片", isPresented: Binding(
            get: { chatBackgroundErrorMessage != nil },
            set: { if !$0 { chatBackgroundErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { chatBackgroundErrorMessage = nil }
        } message: {
            Text(chatBackgroundErrorMessage ?? "请换一张图片后重试。")
        }
    }

    // MARK: - Chat Background

    private var chatBackgroundSettingsSection: some View {
        SettingsSection(
            header: "聊天背景",
            footer: "背景图只显示在聊天界面的底层；Gemini 渐变动画和聊天内容仍显示在它上方。"
        ) {
            PhotosPicker(
                selection: $selectedChatBackgroundItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                HStack(spacing: Spacing.md) {
                    chatBackgroundPickerIcon

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(manager.hasChatBackground ? "更换聊天背景" : "自定义聊天背景")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Text(isLoadingChatBackground
                             ? "正在准备预览…"
                             : (manager.hasChatBackground ? "已设置，点击更换" : "从相册选择图片"))
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Spacer()

                    if isLoadingChatBackground {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoadingChatBackground)

            if manager.hasChatBackground {
                Divider()
                    .padding(.leading, Spacing.md + IconSize.lg + Spacing.md)

                Button {
                    manager.restoreDefaultChatBackground()
                    Haptics.play(.medium)
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "arrow.counterclockwise")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundStyle(theme.error)
                            .frame(width: IconSize.lg, height: IconSize.lg)
                            .background(theme.error.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("恢复默认背景")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.error)
                            Text("移除自定义图片并恢复主题默认背景")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var chatBackgroundPickerIcon: some View {
        if let image = manager.chatBackgroundImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: IconSize.lg, height: IconSize.lg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
        } else {
            Image(systemName: "photo.on.rectangle.angled")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(theme.brandPrimary)
                .frame(width: IconSize.lg, height: IconSize.lg)
                .background(theme.brandPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @MainActor
    private func loadChatBackgroundPreview(from item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingChatBackground = true
        defer {
            isLoadingChatBackground = false
            // Allow selecting the same picture again after cancelling preview.
            selectedChatBackgroundItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                chatBackgroundErrorMessage = "无法读取这张图片，请换一张后重试。"
                return
            }
            pendingChatBackgroundData = data
            pendingChatBackgroundImage = image
            showChatBackgroundPreview = true
        } catch {
            chatBackgroundErrorMessage = "读取图片时出错：\(error.localizedDescription)"
        }
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

/// A confirm-before-save preview that mirrors the chat canvas layer order:
/// selected photo at the bottom, Gemini colour field above it, then messages
/// and composer glass on top.
private struct ChatBackgroundPreviewSheet: View {
    let image: UIImage
    let imageData: Data
    @Bindable var manager: AppearanceManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ChatBackgroundImageView(image: image)
                    .ignoresSafeArea()

                previewGeminiOverlay
                    .ignoresSafeArea()

                previewChatChrome
            }
            .navigationTitle("聊天背景预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveBackground() }
                        .fontWeight(.semibold)
                }
            }
            .alert("无法保存背景", isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "请换一张图片后重试。")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var previewGeminiOverlay: some View {
        ZStack {
            LinearGradient(
                colors: theme.isDark
                    ? [.clear, Color.cyan.opacity(0.18), Color.blue.opacity(0.26)]
                    : [.clear, Color.cyan.opacity(0.16), Color.blue.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.mint.opacity(theme.isDark ? 0.18 : 0.24), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 430
            )
        }
        .allowsHitTesting(false)
    }

    private var previewChatChrome: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            HStack(alignment: .top, spacing: Spacing.sm) {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "sparkles")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.onAccentColor)
                    }

                Text("背景图会显示在渐变动画下方")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.chatBubbleAssistantText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.chatBubbleAssistant.opacity(theme.isDark ? 0.90 : 0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Text("预览效果")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.chatBubbleUserText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.chatBubbleUser.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Text("询问 AI")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.inputPlaceholder)
                Spacer()
                Image(systemName: "waveform")
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(theme.inputBackground.opacity(theme.isDark ? 0.94 : 0.90))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(theme.inputBorder.opacity(0.85), lineWidth: 0.75)
            )
        }
        .padding(Spacing.screenPadding)
    }

    private func saveBackground() {
        do {
            try manager.saveChatBackground(from: imageData)
            Haptics.play(.medium)
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
