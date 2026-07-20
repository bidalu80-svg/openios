import SwiftUI

struct LocalAgentCenterView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var soulService = LocalSoulService.shared
    @State private var skillsService = LocalSkillsService.shared
    @State private var mcpService = LocalMCPAgentService.shared
    @State private var memoryCount = 0
    @State private var memoryEnabled = true

    private var memoryServerURL: String {
        dependencies.apiClient?.baseURL ?? "local"
    }

    private var enabledSkillCount: Int {
        skillsService.enabledSkills.count
    }

    private var enabledMCPCount: Int {
        mcpService.enabledConnections.count
    }

    private var activeModulesCount: Int {
        [
            soulService.hasContent && soulService.profile.isEnabled,
            enabledSkillCount > 0,
            memoryEnabled,
            enabledMCPCount > 0
        ].filter { $0 }.count
    }

    var body: some View {
        List {
            Section {
                overviewCard
            } footer: {
                Text("这些配置都保存在当前设备，会在聊天请求前组成本地上下文，不需要额外服务器。")
            }

            Section {
                NavigationLink {
                    SoulSettingsView()
                } label: {
                    centerRow(
                        icon: "sparkles",
                        title: "SOUL 人设",
                        subtitle: "长期身份、语气、边界和偏好",
                        value: soulService.statusText,
                        tint: .indigo
                    )
                }

                NavigationLink {
                    LocalSkillsSettingsView()
                } label: {
                    centerRow(
                        icon: "cube.box",
                        title: "技能库",
                        subtitle: "本地技能、工作流和规则注入",
                        value: "\(enabledSkillCount)/\(skillsService.skills.count)",
                        tint: .green
                    )
                }

                NavigationLink {
                    MemoriesView()
                } label: {
                    centerRow(
                        icon: "brain",
                        title: "长期记忆",
                        subtitle: "跨对话保存用户偏好和重要信息",
                        value: memoryEnabled ? "\(memoryCount) 条" : "已关闭",
                        tint: .purple
                    )
                }
            } header: {
                Text("人格与上下文")
            } footer: {
                Text("SOUL 更像人设文件，技能更像任务规则，记忆更像长期事实。三者分开管理，聊天时统一注入。")
            }

            Section {
                NavigationLink {
                    LocalMCPAgentSettingsView()
                } label: {
                    centerRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "本地 MCP",
                        subtitle: "角色库、文件、记忆和工具类本地连接",
                        value: "\(enabledMCPCount) 个启用",
                        tint: .cyan
                    )
                }

                NavigationLink {
                    LocalAlpineEnvironmentVariablesView()
                } label: {
                    centerRow(
                        icon: "terminal",
                        title: "环境变量",
                        subtitle: "注入到 Local Alpine 沙箱 shell",
                        value: "\(LocalAlpineEnvironmentStore.shared.variables.count) 个",
                        tint: .orange
                    )
                }
            } header: {
                Text("能力扩展")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("注入顺序", systemImage: "arrow.down.doc")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        orderLine(index: 1, title: "会话系统提示词", detail: "当前聊天或文件夹自己的 system prompt")
                        orderLine(index: 2, title: "本地能力上下文", detail: "模型能力、本地工作区、Local Alpine 和本地工具")
                        orderLine(index: 3, title: "SOUL / 技能 / 记忆", detail: "长期人设、启用技能、跨对话记忆")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("工作方式")
            }
        }
        .navigationTitle("本地智能体")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshMemoryStatus()
        }
        .onAppear {
            Task { await refreshMemoryStatus() }
        }
    }

    private var overviewCard: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .scaledFont(size: 24, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("本地智能体配置中心")
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(theme.textPrimary)

                    Text("\(activeModulesCount) 项启用")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text("集中管理 SOUL、人设、技能、长期记忆和本地工具。聊天时会自动把已启用内容合并进本地上下文。")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func centerRow(
        icon: String,
        title: String,
        subtitle: String,
        value: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(value)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func orderLine(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(theme.brandOnPrimary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.brandPrimary))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func refreshMemoryStatus() async {
        memoryEnabled = await LocalMemoryStore.shared.isEnabled(serverURL: memoryServerURL)
        memoryCount = await LocalMemoryStore.shared.list(serverURL: memoryServerURL).count
    }
}
