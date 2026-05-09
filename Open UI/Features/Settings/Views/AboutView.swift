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
            VStack(spacing: Spacing.sectionGap) {
                // App icon and version
                appHeader

                SettingsSection(header: "关于 Iexa") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Iexa 是一款轻量的 AI 聊天应用，支持日常对话、图像生成、图片和文件理解、本地聊天记录，以及直连多种 API 服务。")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("它把模型、聊天和创作工具集中在一个简洁的移动工作区里。")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)
                }

                // App info
                SettingsSection(header: "应用") {
                    detailRow(label: "版本", value: appVersion)
                    detailRow(label: "构建", value: buildNumber)
                    detailRow(label: "平台", value: "iOS \(UIDevice.current.systemVersion)")
                    detailRow(label: "作者版权", value: "Blank", showDivider: false)
                }

                // Site info
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

                // Credits
                VStack(spacing: Spacing.sm) {
                    Text("Iexa")
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
            Image("AppIconImage")
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("Iexa")
                .scaledFont(size: 28, weight: .bold)
                .foregroundStyle(theme.textPrimary)

            Text("AI 聊天、图像工具和本地工作区")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)

            Text("v\(appVersion) (\(buildNumber))")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.top, Spacing.lg)
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
