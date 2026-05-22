import SwiftUI

/// About screen showing app version and local app details.
struct AboutView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                appHeader

                SettingsSection(header: "关于 Iexa") {
                    aboutNarrative
                }

                SettingsSection(header: "核心能力") {
                    VStack(spacing: 0) {
                        capabilityRow(
                            icon: "bubble.left.and.text.bubble.right.fill",
                            title: "多模型智能对话",
                            description: "面向日常问答、长文理解、方案推演和连续创作，保留清晰上下文与会话记录。"
                        )
                        capabilityRow(
                            icon: "photo.on.rectangle.angled",
                            title: "图像与文件工作流",
                            description: "支持图片生成、图片理解、文档解析和附件发送，让素材、内容和模型能力在同一处流转。"
                        )
                        capabilityRow(
                            icon: "terminal.fill",
                            title: "本地工作区与任务执行",
                            description: "集成本地聊天记录、工作区文件和终端能力，适合移动端轻量开发、资料整理和自动化任务。"
                        )
                        capabilityRow(
                            icon: "server.rack",
                            title: "灵活站点与 API 接入",
                            description: "可连接自托管服务或第三方兼容接口，方便在不同模型、不同服务和不同工作环境间切换。",
                            showDivider: false
                        )
                    }
                }

                SettingsSection(header: "应用") {
                    detailRow(label: "版本", value: appVersion)
                    detailRow(label: "构建", value: buildNumber)
                    detailRow(label: "平台", value: "iOS \(UIDevice.current.systemVersion)")
                    detailRow(label: "作者版权", value: "Blank", showDivider: false)
                }

                SettingsSection(header: "站点") {
                    detailRow(label: "名称", value: viewModel.serverName)
                    if let version = viewModel.serverVersion {
                        detailRow(label: "站点版本", value: version)
                    }
                    detailRow(
                        label: "URL",
                        value: viewModel.serverURL,
                        showDivider: false
                    )
                }

                VStack(spacing: Spacing.sm) {
                    Text("Iexa · 为移动端 AI 工作流打造")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, Spacing.lg)
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
    }

    private var appHeader: some View {
        VStack(spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Iexa")
                        .scaledFont(size: 32, weight: .bold)
                        .foregroundStyle(theme.textPrimary)

                    Text("移动端 AI 创作与工作空间")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)

                    Text("v\(appVersion) (\(buildNumber))")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(theme.surfaceContainer)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }

            Text("把聊天、图像、文件理解、API 接入和本地工作区整合成一个随身 AI 控制台。无论是临时提问、整理资料、生成内容，还是处理项目文件，Iexa 都让模型能力更贴近日常工作。")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.sm)], spacing: Spacing.sm) {
                heroTag("AI 对话")
                heroTag("图像创作")
                heroTag("文件理解")
                heroTag("本地工作区")
            }
        }
        .padding(Spacing.md)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.lg)
    }

    private var aboutNarrative: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("为真实工作场景设计的 AI 移动工作台")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Iexa 不只是一个聊天入口，而是一个把模型能力、内容创作、资料处理和本地任务连接起来的移动工作区。它适合在手机上快速发起思考、整理复杂信息、处理图片与文件，并把常用模型和 API 服务放进同一个清晰、克制、可持续使用的界面里。")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text("应用强调轻量、直接和可掌控：对话记录保留在本地体验中，站点配置清楚可见，工作流尽量减少多余步骤。你可以把它当作随身 AI 助手，也可以把它当作连接模型、资料、文件和任务执行的小型控制中心。")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
    }

    private func heroTag(_ title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)

            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.horizontal, Spacing.sm)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
    }

    private func capabilityRow(
        icon: String,
        title: String,
        description: String,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: IconSize.lg, height: IconSize.lg)
                    .background(theme.accentTint)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)

                    Text(description)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md + IconSize.lg + Spacing.md)
            }
        }
    }

    private func detailRow(
        label: String,
        value: String,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text(value)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md)
            }
        }
    }

}
