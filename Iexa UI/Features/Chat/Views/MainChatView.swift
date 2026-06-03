import Combine
import Darwin
import Foundation
import QuartzCore
import SwiftUI

/// The primary authenticated view that shows the chat screen as the
/// landing page, with a slide-out drawer for conversation history,
/// settings, and notes — matching the Flutter app's layout.
///
/// ## Performance
/// - The drawer is **always in the view tree** (offset-based, not `if/else`),
///   so toggling it never destroys/recreates its view hierarchy.
/// - The main content is **never** `.disabled()` — the dimming overlay
///   intercepts taps instead, avoiding a full re-render of the chat stack.
/// - Haptic feedback uses the pre-prepared `Haptics` service.
struct MainChatView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Controls the drawer visibility.
    @State private var showDrawer = false

    /// Controls the settings sheet presentation.
    @State private var showSettings = false

    /// Controls the notes sheet presentation.
    @State private var showNotes = false

    /// Controls the workspace sheet presentation.
    @State private var showWorkspace = false

    /// Controls the calendar sheet presentation.
    @State private var showCalendar = false

    /// Controls the weather sheet presentation.
    @State private var showWeather = false

    /// Controls the local Alpine terminal presentation.
    @State private var showLocalAlpineTerminal = false

    /// Controls the local Alpine workspace file browser presentation.
    @State private var showLocalWorkspaceBrowser = false

    /// Controls the automations sheet presentation.
    @State private var showAutomations = false

    /// Controls the memories sheet presentation.
    @State private var showMemories = false

    /// Controls the channels list sheet presentation.
    @State private var showChannels = false
    
    /// Controls the create channel sheet presentation.
    @State private var showCreateChannel = false

    /// Controls the archived chats sheet presentation.
    @State private var showArchivedChats = false

    /// Controls the shared chats sheet presentation.
    @State private var showSharedChats = false

    /// Controls the admin console sheet presentation (admin users only).
    @State private var showAdminConsole = false

    /// Channel list VM for sidebar display.
    @State private var channelListVM = ChannelListViewModel()

    /// The conversation currently being viewed. `nil` = new chat.
    @State private var activeConversationId: String?

    /// The channel currently being viewed. When set, replaces main content with ChannelDetailView.
    @State private var activeChannelId: String?

    /// Monotonically increasing counter to force new-chat view recreation.
    @State private var newChatGeneration: Int = 0

    /// Conversation list view model (shared with drawer).
    @State private var listViewModel = ChatListViewModel()

    /// Controls the "delete all" confirmation dialog.
    @State private var showDeleteAllConfirmation = false

    /// Controls the "delete selected" confirmation dialog.
    @State private var showDeleteSelectedConfirmation = false

    /// Single-conversation delete confirmation (from drawer context menu).
    @State private var deletingConversation: Conversation?

    /// Channel delete confirmation (from drawer context menu).
    @State private var deletingChannelId: String?

    /// Whether the "create folder" sheet is visible.
    @State private var showCreateFolderSheet = false

    /// When set, the main content area shows a folder workspace view
    /// (folder icon + name centered, chat input below). Any new chat
    /// started will be assigned to this folder with its system prompt.
    @State private var activeFolderWorkspaceId: String?

    /// Tracks whether socket reconnect handler has been registered.
    @State private var hasRegisteredSocketHandlers = false

    /// Whether the drawer "Chats" header is being targeted by a drag.
    @State private var drawerChatsDropActive: Bool = false

    /// Top-level section collapse states (persisted across launches).
    @AppStorage("sidebar_folders_expanded") private var foldersExpanded: Bool = true
    @AppStorage("sidebar_channels_expanded") private var channelsExpanded: Bool = true
    @AppStorage("sidebar_chats_expanded") private var chatsExpanded: Bool = true
    /// Tracks which time-group sub-sections are collapsed (e.g. "Pinned", "Today").
    @State private var collapsedSections: Set<String> = []

    /// Cached container width from GeometryReader (avoids deprecated UIScreen.main).
    @State private var containerWidth: CGFloat = 360
    @State private var containerHeight: CGFloat = 820

    /// Live drag offset for interactive drawer sliding.
    @State private var dragOffset: CGFloat = 0

    /// Whether a drawer drag is in progress (prevents animation fighting).
    @State private var isDraggingDrawer = false

    // MARK: Terminal file browser (right-side panel)
    @State private var showFileBrowser = false
    @State private var fileBrowserDragOffset: CGFloat = 0
    @State private var isDraggingFileBrowser = false
    @State private var terminalBrowserVM = TerminalBrowserViewModel()
    @AppStorage("performanceWindowEnabled") private var performanceWindowEnabled = true
    @AppStorage("desktopPetEnabled") private var desktopPetEnabled = false
    @AppStorage("desktopPetOffsetX") private var desktopPetOffsetX = 0.0
    @AppStorage("desktopPetOffsetY") private var desktopPetOffsetY = 0.0
    @State private var desktopPetExpanded = false
    @State private var desktopPetDragOffset: CGSize = .zero
    @State private var desktopPetIsDragging = false

    /// Rename conversation state.
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""

    /// Share sheet state.
    @State private var sharingConversation: Conversation?

    /// Export file URL for share sheet.
    @State private var exportFileURL: URL?
    @State private var showExportShareSheet = false

    /// Whether title is being AI-generated.
    @State private var isGeneratingTitle = false

    /// Whether a chat export is in progress (shows loading overlay).
    @State private var isExporting = false
    @State private var exportError: String?

    /// Drawer width as a fraction of container width, capped.
    private var drawerWidth: CGFloat {
        min(containerWidth * 0.82, 360)
    }

    private var usesDirectProvider: Bool {
        dependencies.conversationManager?.usesLocalConversationStore == true
    }

    private var sidebarUserAvatarDataURI: String? {
        guard let imageURL = dependencies.authViewModel.currentUser?.profileImageURL,
              imageURL.hasPrefix("data:") else { return nil }
        return imageURL
    }

    private var sidebarUserAvatarURL: URL? {
        guard sidebarUserAvatarDataURI == nil,
              let user = dependencies.authViewModel.currentUser else { return nil }

        if dependencies.apiClient?.providerType != .iexa {
            return dependencies.serverConfigStore.activeServer?.resolvedImageURL(from: user.profileImageURL)
                ?? dependencies.serverConfigStore.activeServer?.siteIconURL
        }

        if let external = dependencies.serverConfigStore.activeServer?.resolvedImageURL(from: user.profileImageURL) {
            return external
        }

        guard let baseURL = dependencies.apiClient?.baseURL,
              !user.id.isEmpty, !baseURL.isEmpty else { return nil }
        let v = dependencies.authViewModel.profileImageVersion
        return URL(string: "\(baseURL)/api/v1/users/\(user.id)/profile/image?v=\(v)")
    }

    var body: some View {
        @Bindable var bindableRouter = router
        mainContent(voiceCallBinding: $bindableRouter.isVoiceCallPresented)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(containerWidth - newWidth) > 1 {
                    containerWidth = newWidth
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                if abs(containerHeight - newHeight) > 1 {
                    containerHeight = newHeight
                }
            }
    }

    /// Computes the effective drawer X offset (0 = fully open, -drawerWidth = fully closed).
    /// Combines the base `showDrawer` state with the live `dragOffset` during a gesture.
    private var effectiveDrawerX: CGFloat {
        let base: CGFloat = showDrawer ? 0 : -drawerWidth
        let combined = base + dragOffset
        return min(0, max(-drawerWidth, combined))
    }

    /// Drawer open fraction (0 = fully closed, 1 = fully open) — drives dimming opacity.
    private var drawerFraction: CGFloat {
        let fraction = (effectiveDrawerX + drawerWidth) / drawerWidth
        return min(1, max(0, fraction))
    }

    // MARK: File Browser Computed Properties (right-side panel, mirrors drawer)

    /// File browser panel width.
    private var fileBrowserWidth: CGFloat {
        min(containerWidth * 0.85, 380)
    }

    /// Effective X offset for the file browser (containerWidth = off-screen right,
    /// containerWidth - fileBrowserWidth = fully visible).
    private var effectiveFileBrowserX: CGFloat {
        let base: CGFloat = showFileBrowser ? (containerWidth - fileBrowserWidth) : containerWidth
        let combined = base + fileBrowserDragOffset
        return max(containerWidth - fileBrowserWidth, min(containerWidth, combined))
    }

    /// File browser open fraction (0 = closed, 1 = fully open).
    private var fileBrowserFraction: CGFloat {
        let fraction = (containerWidth - effectiveFileBrowserX) / fileBrowserWidth
        return min(1, max(0, fraction))
    }

    /// Whether the current active chat has terminal enabled with a server selected.
    private var isTerminalActiveInCurrentChat: Bool {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        return vm.terminalEnabled && vm.selectedTerminalServer != nil
    }

    // MARK: - Main Content Pipeline
    // Split into distinct sub-methods so the Swift type checker can resolve
    // each modifier group independently (fixes "unable to type-check" error).

    private func mainContent(voiceCallBinding: Binding<Bool>) -> some View {
        applyAccountSwitchHandler(
            content: applyOverlays(
                content: applyLifecycleHandlers(
                    content: applyDialogsAndAlerts(
                        content: applySheets(
                            content: mainZStack(voiceCallBinding: voiceCallBinding),
                            voiceCallBinding: voiceCallBinding
                        )
                    )
                )
            )
        )
    }

    // MARK: - Main ZStack (Core Layout)

    @ViewBuilder
    private func mainZStack(voiceCallBinding: Binding<Bool>) -> some View {
        ZStack(alignment: .leading) {
            // MARK: Main chat content
            NavigationStack {
                chatContent
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                toggleDrawer()
                            } label: {
                                Image(systemName: "line.3.horizontal")
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(width: 34, height: 34)
                                    .iexaToolbarGlass(cornerRadius: 17, compact: true)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Menu")
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            if activeChannelId != nil {
                                Button {
                                    startNewChat()
                                } label: {
                                    NewConversationIcon(size: 18)
                                        .foregroundStyle(theme.textSecondary)
                                        .frame(width: 34, height: 34)
                                        .iexaToolbarGlass(cornerRadius: 17, compact: true)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("新对话")
                            }
                        }
                    }
                    .simultaneousGesture(rightEdgeFileBrowserGesture)
            }
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(drawerFraction < 0.01 && !isDraggingDrawer && !isDraggingFileBrowser)

            // MARK: Dimming overlay
            Color.black
                .opacity(0.4 * drawerFraction)
                .ignoresSafeArea()
                .allowsHitTesting(drawerFraction > 0.01)
                .onTapGesture {
                    closeDrawerAnimated()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingDrawer = false
                            if horizontal < -(drawerWidth * 0.3) || velocity < -500 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: Drawer
            drawerContent
                .frame(width: drawerWidth)
                .offset(x: effectiveDrawerX)
                .accessibilityHidden(drawerFraction < 0.01)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingDrawer = false
                            if horizontal < -(drawerWidth * 0.3) || velocity < -500 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: File browser dimming overlay (right side — only when terminal is active)
            if isTerminalActiveInCurrentChat {
            Color.black
                .opacity(0.4 * fileBrowserFraction)
                .ignoresSafeArea()
                .allowsHitTesting(fileBrowserFraction > 0.01)
                .onTapGesture {
                    closeFileBrowserAnimated()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal > 0 else { return }
                            isDraggingFileBrowser = true
                            fileBrowserDragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingFileBrowser else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingFileBrowser = false
                            if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                                closeFileBrowserAnimated()
                            } else {
                                openFileBrowserAnimated()
                            }
                        }
                )

            // MARK: File browser panel (right side)
            Group {
                if terminalBrowserVM.usesLocalAlpine {
                    LocalAlpineWorkspacePanelView(
                        viewModel: terminalBrowserVM,
                        onDismiss: { closeFileBrowserAnimated() }
                    )
                        .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                } else {
                    TerminalBrowserView(
                        viewModel: terminalBrowserVM,
                        onDismiss: { closeFileBrowserAnimated() }
                    )
                }
            }
            .frame(width: fileBrowserWidth)
            .background(theme.background)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .shadow(color: .black.opacity(0.2), radius: 16, x: -4)
            .offset(x: effectiveFileBrowserX)
            .accessibilityHidden(fileBrowserFraction < 0.01)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        let horizontal = value.translation.width
                        guard horizontal > 0 else { return }
                        isDraggingFileBrowser = true
                        fileBrowserDragOffset = horizontal
                    }
                    .onEnded { value in
                        guard isDraggingFileBrowser else { return }
                        let horizontal = value.translation.width
                        let velocity = value.velocity.width
                        isDraggingFileBrowser = false
                        if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                            closeFileBrowserAnimated()
                        } else {
                            openFileBrowserAnimated()
                        }
                    }
            )
            } // end if isTerminalActiveInCurrentChat

            if performanceWindowEnabled && activeChannelId == nil && drawerFraction < 0.01 && fileBrowserFraction < 0.01 {
                PerformanceWindowView(topInset: 58, trailingInset: 12, bottomInset: 116)
                    .transition(.opacity)
                    .zIndex(18)
            }

            if desktopPetEnabled && desktopPetExpanded && activeChannelId == nil && drawerFraction < 0.01 && fileBrowserFraction < 0.01 {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapseDesktopPet() }
                    .zIndex(19)
            }

            if desktopPetEnabled && activeChannelId == nil && drawerFraction < 0.01 && fileBrowserFraction < 0.01 {
                desktopPetOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 18)
                    .padding(.bottom, 92)
                    .offset(currentDesktopPetOffset)
                    .transition(.scale(scale: 0.88, anchor: .bottomTrailing).combined(with: .opacity))
                    .zIndex(20)
            }

            // MARK: Left edge overlay — exclusively captures left-edge swipe to open drawer.
            // Sits on top of the NavigationStack so it intercepts touches before they
            // reach background content. Uses .gesture() (not .simultaneousGesture) so
            // background taps/scrolls cannot fire during the drag.
            if !showDrawer {
                Color.clear
                    .frame(width: 20)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onChanged { value in
                                let horizontal = value.translation.width
                                let vertical = abs(value.translation.height)
                                guard horizontal > vertical else { return }
                                if !isDraggingDrawer {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                                isDraggingDrawer = true
                                dragOffset = horizontal
                            }
                            .onEnded { value in
                                guard isDraggingDrawer else { return }
                                let horizontal = value.translation.width
                                let velocity = value.velocity.width
                                isDraggingDrawer = false
                                if horizontal > drawerWidth * 0.4 || velocity > 500 {
                                    openDrawerAnimated()
                                } else {
                                    closeDrawerAnimated()
                                }
                            }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
    }

    // MARK: - Presentation Routing

    private enum MainChatSheetRoute: Identifiable {
        case settings
        case notes
        case createChannel
        case createFolder
        case editFolder(ChatFolder)
        case renameConversation(Conversation)
        case exportShare(URL)
        case shareConversation(Conversation)
        case archivedChats
        case sharedChats
        case workspace
        case calendar
        case weather
        case localWorkspaceBrowser
        case automations
        case memories
        case adminConsole
        case accountPicker

        var id: String {
            switch self {
            case .settings: return "settings"
            case .notes: return "notes"
            case .createChannel: return "createChannel"
            case .createFolder: return "createFolder"
            case .editFolder(let folder): return "editFolder-\(folder.id)"
            case .renameConversation(let conversation): return "renameConversation-\(conversation.id)"
            case .exportShare(let url): return "exportShare-\(url.path)"
            case .shareConversation(let conversation): return "shareConversation-\(conversation.id)"
            case .archivedChats: return "archivedChats"
            case .sharedChats: return "sharedChats"
            case .workspace: return "workspace"
            case .calendar: return "calendar"
            case .weather: return "weather"
            case .localWorkspaceBrowser: return "localWorkspaceBrowser"
            case .automations: return "automations"
            case .memories: return "memories"
            case .adminConsole: return "adminConsole"
            case .accountPicker: return "accountPicker"
            }
        }
    }

    private enum MainChatCoverRoute: Identifiable {
        case channels
        case localAlpineTerminal

        var id: String {
            switch self {
            case .channels: return "channels"
            case .localAlpineTerminal: return "localAlpineTerminal"
            }
        }
    }

    private var activeSheetRoute: MainChatSheetRoute? {
        if showSettings { return .settings }
        if showNotes { return .notes }
        if showCreateChannel { return .createChannel }
        if showCreateFolderSheet { return .createFolder }
        if let folder = listViewModel.folderViewModel.editingFolder { return .editFolder(folder) }
        if let conversation = renamingConversation { return .renameConversation(conversation) }
        if showExportShareSheet, let url = exportFileURL { return .exportShare(url) }
        if let conversation = sharingConversation { return .shareConversation(conversation) }
        if showArchivedChats { return .archivedChats }
        if showSharedChats { return .sharedChats }
        if showWorkspace { return .workspace }
        if showCalendar { return .calendar }
        if showWeather { return .weather }
        if showLocalWorkspaceBrowser { return .localWorkspaceBrowser }
        if showAutomations { return .automations }
        if showMemories { return .memories }
        if showAdminConsole { return .adminConsole }
        if dependencies.authViewModel.showAccountPicker { return .accountPicker }
        return nil
    }

    private var activeCoverRoute: MainChatCoverRoute? {
        if showChannels { return .channels }
        if showLocalAlpineTerminal { return .localAlpineTerminal }
        return nil
    }

    private var activeSheetBinding: Binding<MainChatSheetRoute?> {
        Binding(
            get: { activeSheetRoute },
            set: { route in
                if route == nil {
                    dismissSheetRoute(activeSheetRoute)
                }
            }
        )
    }

    private var activeCoverBinding: Binding<MainChatCoverRoute?> {
        Binding(
            get: { activeCoverRoute },
            set: { route in
                if route == nil {
                    dismissCoverRoute(activeCoverRoute)
                }
            }
        )
    }

    private func applySheets<Content: View>(content: Content, voiceCallBinding: Binding<Bool>) -> some View {
        content
            .sheet(item: activeSheetBinding) { route in
                sheetContent(for: route)
            }
            .sheet(isPresented: voiceCallBinding, onDismiss: {
                // Dragging the sheet down counts as minimizing if the call is still active.
                if !router.isVoiceCallMinimized, router.voiceCallViewModel != nil {
                    router.minimizeVoiceCall()
                }
            }) {
                if let voiceCallVM = router.voiceCallViewModel {
                    VoiceCallView(viewModel: voiceCallVM)
                        .environment(dependencies)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                        .presentationCornerRadius(24)
                        .presentationBackground(.ultraThinMaterial)
                        .interactiveDismissDisabled(false)
                }
            }
            .fullScreenCover(item: activeCoverBinding) { route in
                coverContent(for: route)
            }
            .onChange(of: router.isVoiceCallPresented) { _, isPresented in
                if !isPresented && !router.isVoiceCallMinimized {
                    router.voiceCallViewModel = nil
                }
            }
            .onChange(of: listViewModel.folderViewModel.showCreateSheet) { _, show in
                if show {
                    listViewModel.folderViewModel.showCreateSheet = false
                    showCreateFolderSheet = true
                }
            }
    }

    @ViewBuilder
    private func sheetContent(for route: MainChatSheetRoute) -> some View {
        switch route {
        case .settings:
            SettingsView(
                viewModel: dependencies.authViewModel,
                appearanceManager: dependencies.appearanceManager
            )
            .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme ?? systemColorScheme)
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .notes:
            NavigationStack {
                NotesListView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            sheetCloseButton { showNotes = false }
                        }
                    }
            }

        case .createChannel:
            CreateChannelSheet(
                onCreate: { name, description, type, isPrivate, memberIds in
                    Task {
                        let channelName = name.isEmpty ? "new-channel" : name
                        if let channel = await channelListVM.createChannel(
                            name: channelName,
                            description: description,
                            type: type,
                            isPrivate: type == .dm ? true : isPrivate
                        ) {
                            if !memberIds.isEmpty {
                                try? await dependencies.apiClient?.addChannelMembers(
                                    id: channel.id,
                                    userIds: memberIds
                                )
                            }
                            activeChannelId = channel.id
                            activeConversationId = nil
                        }
                    }
                },
                apiClient: dependencies.apiClient,
                allUsers: channelListVM.allServerUsers
            )

        case .createFolder:
            CreateFolderSheet(apiClient: dependencies.apiClient) { name, data, meta in
                let parentId = listViewModel.folderViewModel.createSubfolderParentId
                listViewModel.folderViewModel.createSubfolderParentId = nil
                Task {
                    await listViewModel.folderViewModel.createFolder(
                        name: name,
                        parentId: parentId,
                        data: data,
                        meta: meta
                    )
                }
            }

        case .editFolder(let folder):
            EditFolderSheet(
                folder: folder,
                apiClient: dependencies.apiClient
            ) { name, data, meta in
                Task {
                    await listViewModel.folderViewModel.updateFolderSettings(
                        id: folder.id,
                        name: name,
                        data: data,
                        meta: meta
                    )
                }
            }

        case .renameConversation(let conversation):
            renameConversationSheet(conversation)

        case .exportShare(let url):
            ShareSheet(items: [url])

        case .shareConversation(let conversation):
            if let apiClient = dependencies.apiClient {
                ShareChatSheet(
                    conversation: conversation,
                    apiClient: apiClient,
                    serverBaseURL: apiClient.baseURL,
                    onShareIdUpdated: { shareId in
                        listViewModel.updateShareId(for: conversation.id, shareId: shareId)
                    },
                    onClone: { cloned in
                        activeConversationId = cloned.id
                        SharedDataService.shared.saveLastActiveConversationId(cloned.id)
                        closeDrawer()
                    }
                )
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }

        case .archivedChats:
            ArchivedChatsView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .sharedChats:
            SharedChatsView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .workspace:
            WorkspaceView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .calendar:
            CalendarView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .weather:
            WeatherView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .localWorkspaceBrowser:
            LocalWorkspaceFileBrowserView()
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)

        case .automations:
            AutomationsListView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .memories:
            NavigationStack {
                MemoriesView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            sheetCloseButton { showMemories = false }
                        }
                    }
            }
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)

        case .adminConsole:
            NavigationStack {
                AdminConsoleView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            sheetCloseButton { showAdminConsole = false }
                        }
                    }
            }
            .environment(dependencies)
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            .presentationCornerRadius(20)

        case .accountPicker:
            AccountPickerSheet(
                viewModel: dependencies.authViewModel,
                onDismiss: { dependencies.authViewModel.showAccountPicker = false }
            )
            .environment(dependencies)
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
    }

    @ViewBuilder
    private func coverContent(for route: MainChatCoverRoute) -> some View {
        switch route {
        case .channels:
            NavigationStack {
                ChannelsListView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            sheetCloseButton { showChannels = false }
                        }
                    }
            }
            .environment(dependencies)
            .environment(router)

        case .localAlpineTerminal:
            LocalAlpineTerminalConsoleView {
                showLocalAlpineTerminal = false
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func sheetCloseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 32, height: 32)
                .background(Color(uiColor: .systemGray5).opacity(0.6))
                .clipShape(Circle())
        }
    }

    private func dismissSheetRoute(_ route: MainChatSheetRoute?) {
        switch route {
        case .settings:
            showSettings = false
        case .notes:
            showNotes = false
        case .createChannel:
            showCreateChannel = false
        case .createFolder:
            showCreateFolderSheet = false
        case .editFolder:
            listViewModel.folderViewModel.editingFolder = nil
        case .renameConversation:
            renamingConversation = nil
        case .exportShare:
            showExportShareSheet = false
            if let url = exportFileURL {
                try? FileManager.default.removeItem(at: url)
                exportFileURL = nil
            }
        case .shareConversation:
            sharingConversation = nil
        case .archivedChats:
            showArchivedChats = false
        case .sharedChats:
            showSharedChats = false
        case .workspace:
            showWorkspace = false
        case .calendar:
            showCalendar = false
        case .weather:
            showWeather = false
        case .localWorkspaceBrowser:
            showLocalWorkspaceBrowser = false
        case .automations:
            showAutomations = false
        case .memories:
            showMemories = false
        case .adminConsole:
            showAdminConsole = false
        case .accountPicker:
            dependencies.authViewModel.showAccountPicker = false
        case .none:
            break
        }
    }

    private func dismissCoverRoute(_ route: MainChatCoverRoute?) {
        switch route {
        case .channels:
            showChannels = false
        case .localAlpineTerminal:
            showLocalAlpineTerminal = false
        case .none:
            break
        }
    }

    // MARK: - Rename Conversation Sheet (extracted for readability)

    @ViewBuilder
    private func renameConversationSheet(_ conv: Conversation) -> some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                TextField("Chat title", text: $renameText)
                    .scaledFont(size: 16)
                    .padding(Spacing.md)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Button {
                    Task { await generateTitleForRename(conv) }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isGeneratingTitle {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGeneratingTitle ? "Generating..." : "Generate")
                    }
                    .scaledFont(size: 14, weight: .medium)
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(theme.brandPrimary)
                .disabled(isGeneratingTitle)

                Spacer()
            }
            .padding(Spacing.lg)
            .navigationTitle("Rename Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renamingConversation = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newTitle.isEmpty else { return }
                        listViewModel.renamingConversation = conv
                        listViewModel.renameText = newTitle
                        Task { await listViewModel.commitRename() }
                        renamingConversation = nil
                    }
                    .fontWeight(.semibold)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Confirmation Dialogs & Alerts

    private func applyDialogsAndAlerts<Content: View>(content: Content) -> some View {
        content
            // Archive all confirmation
            .confirmationDialog(
                "Archive All Chats",
                isPresented: $listViewModel.showArchiveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Archive All", role: .destructive) {
                    Task {
                        await listViewModel.archiveAllConversations()
                        activeConversationId = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will archive all your conversations. You can unarchive them later from the web interface.")
            }
            // Delete all confirmation
            .confirmationDialog(
                "Delete All Chats",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await listViewModel.deleteAllConversations()
                        startNewChat()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all your conversations. This action cannot be undone.")
            }
            // Delete selected confirmation
            .confirmationDialog(
                "Delete Selected Chats",
                isPresented: $showDeleteSelectedConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(listViewModel.selectedCount) Chat\(listViewModel.selectedCount == 1 ? "" : "s")", role: .destructive) {
                    let shouldResetToNewChat = activeConversationId.map { listViewModel.selectedConversationIds.contains($0) } ?? false
                    Task {
                        await listViewModel.deleteSelectedConversations()
                        if shouldResetToNewChat { startNewChat() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \(listViewModel.selectedCount) selected conversation\(listViewModel.selectedCount == 1 ? "" : "s"). This action cannot be undone.")
            }
            // Folder rename prompt
            .alert(
                "Rename Folder",
                isPresented: .init(
                    get: { listViewModel.folderViewModel.renamingFolder != nil },
                    set: { if !$0 { listViewModel.folderViewModel.renamingFolder = nil } }
                )
            ) {
                TextField(
                    "Folder Name",
                    text: Bindable(listViewModel.folderViewModel).renameText
                )
                Button("Cancel", role: .cancel) {
                    listViewModel.folderViewModel.renamingFolder = nil
                }
                Button("Rename") {
                    Task { await listViewModel.folderViewModel.commitRename() }
                }
            }
            // Single-conversation delete confirmation
            .confirmationDialog(
                "Delete \"\(deletingConversation?.title ?? "")\"?",
                isPresented: .init(
                    get: { deletingConversation != nil },
                    set: { if !$0 { deletingConversation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let conv = deletingConversation {
                        let deletedId = conv.id
                        deletingConversation = nil
                        Task {
                            await listViewModel.deleteConversation(id: deletedId)
                            if activeConversationId == deletedId {
                                startNewChat()
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingConversation = nil
                }
            } message: {
                Text("This action cannot be undone.")
            }
            // Channel delete confirmation
            .confirmationDialog(
                "Delete Channel?",
                isPresented: .init(
                    get: { deletingChannelId != nil },
                    set: { if !$0 { deletingChannelId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Channel", role: .destructive) {
                    if let channelId = deletingChannelId {
                        let wasActive = activeChannelId == channelId
                        deletingChannelId = nil
                        Task {
                            try? await dependencies.apiClient?.deleteChannel(id: channelId)
                            await channelListVM.refreshChannels()
                            if wasActive { startNewChat() }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingChannelId = nil
                }
            } message: {
                Text("This will permanently delete this channel and all its messages.")
            }
            // Export error alert
            .alert("Export Failed", isPresented: .init(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "") }
    }

    // MARK: - Lifecycle Handlers (.task, .onChange, .onReceive)

    private func applyLifecycleHandlers<Content: View>(content: Content) -> some View {
        content
            .task {
                if let manager = dependencies.conversationManager {
                    listViewModel.configure(with: manager)
                }
                if let folderManager = dependencies.folderManager {
                    listViewModel.folderViewModel.configure(with: folderManager)
                }
                // Configure and load channels only for Iexa native server servers.
                if !usesDirectProvider, let apiClient = dependencies.apiClient {
                    var userId = dependencies.authViewModel.currentUser?.id
                    if userId == nil || userId?.isEmpty == true {
                        userId = try? await apiClient.getCurrentUser().id
                    }
                    channelListVM.configure(apiClient: apiClient, socket: dependencies.socketService, currentUserId: userId)
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.loadConversations() }
                    if dependencies.conversationManager?.usesLocalConversationStore != true {
                        group.addTask { await listViewModel.folderViewModel.loadFolders() }
                    }
                    if !usesDirectProvider {
                        group.addTask { await dependencies.fetchTaskConfig() }
                        group.addTask { await channelListVM.loadChannels() }
                    }
                }
                if !usesDirectProvider {
                    registerSocketReconnectHandler()
                }
                // Wire up channel notification tap → navigate to that channel
                NotificationService.shared.onOpenChannel = { channelId in
                    NotificationCenter.default.post(name: .navigateToChannel, object: channelId)
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active && oldPhase != .active {
                    Task { await refreshAllDataOnForeground() }
                }
            }
            .onChange(of: activeConversationId) { _, _ in
                // Reset terminal file browser when switching conversations
                // so it doesn't show stale state from the previous chat
                if showFileBrowser { closeFileBrowserAnimated() }
                terminalBrowserVM.reset()
            }
            .onChange(of: activeChannelId) { _, newId in
                // When entering a channel, the server marks it as read via GET /channels/{id}.
                // Refresh the channel list after a short delay to clear the unread badge.
                if newId != nil && !usesDirectProvider {
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        await channelListVM.refreshChannels()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationTitleUpdated)) { notification in
                guard let userInfo = notification.userInfo,
                      let conversationId = userInfo["conversationId"] as? String,
                      let title = userInfo["title"] as? String
                else { return }
                listViewModel.updateTitle(for: conversationId, title: title)
                let folderVM = listViewModel.folderViewModel
                for idx in folderVM.folders.indices {
                    if let chatIdx = folderVM.folders[idx].chats.firstIndex(where: { $0.id == conversationId }) {
                        folderVM.folders[idx].chats[chatIdx].title = title
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .adminClonedChat)) { notification in
                if let conversationId = notification.object as? String {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        activeConversationId = conversationId
                        SharedDataService.shared.saveLastActiveConversationId(conversationId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToChannel)) { notification in
                if let channelId = notification.object as? String {
                    activeChannelId = channelId
                    activeConversationId = nil
                    Haptics.play(.light)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIDismissOverlays)) { _ in
                // Quick action requested — dismiss any active sheet/cover so
                // the new action doesn't stack on top of the old one.
                showSettings = false
                showNotes = false
                showChannels = false
                showCreateChannel = false
                showCreateFolderSheet = false
                showExportShareSheet = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINewChannel)) { _ in
                // Widget "Channel" button — open the create-channel sheet
                if !usesDirectProvider {
                    showCreateChannel = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINewChatWithFocus)) { _ in
                // Widget "Ask Iexa" bar — start new chat and auto-focus keyboard
                startNewChat()
                // Give the view time to settle before requesting keyboard focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIWidgetVoiceCall)) { _ in
                // Widget mic button — start a voice call with full configuration
                // (mirrors ChatDetailView's startVoiceCall pattern)
                let voiceCallVM = dependencies.makeVoiceCallViewModel()
                let chatVM = dependencies.activeChatStore.viewModel(for: nil)
                if let manager = dependencies.conversationManager {
                    let modelName = dependencies.activeChatStore.cachedModels
                        .first(where: { $0.id == dependencies.activeChatStore.cachedSelectedModelId })?.name
                        ?? "AI Assistant"
                    voiceCallVM.configure(
                        conversationManager: manager,
                        chatViewModel: chatVM,
                        modelName: modelName
                    )
                }
                router.presentVoiceCall(viewModel: voiceCallVM)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openIexaTerminalBrowser)) { _ in
                guard activeChannelId == nil else { return }
                showSettings = false
                showNotes = false
                showChannels = false
                showCreateChannel = false
                showCreateFolderSheet = false
                showExportShareSheet = false
                openFileBrowserAnimated()
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationListNeedsRefresh)) { _ in
                Task {
                    if dependencies.conversationManager?.usesLocalConversationStore == true {
                        await listViewModel.refreshConversations()
                    } else {
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await listViewModel.refreshConversations() }
                            group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                        }
                    }
                }
            }
    }

    /// Watches auth identity changes via `.onChange` and performs a
    /// full app state reset when the user switches accounts/sites. This is intentionally a
    /// separate function from `applyLifecycleHandlers` — the Swift type-checker
    /// has a complexity limit that `applyLifecycleHandlers` already approaches,
    /// and adding another modifier there causes a "unable to type-check" build
    /// error. Keeping it here in its own tiny function sidesteps that limit.
    private func applyAccountSwitchHandler<Content: View>(content: Content) -> some View {
        content
            .onChange(of: dependencies.authViewModel.accountSwitchCount) {
                resetChatStateAfterIdentityChange()
            }
            .onChange(of: dependencies.authViewModel.serverSwitchCount) {
                resetChatStateAfterIdentityChange()
            }
    }

    private func resetChatStateAfterIdentityChange() {
        // Account/site changed — drop state that belongs to the previous API.
        activeConversationId = nil
        activeChannelId = nil
        activeFolderWorkspaceId = nil
        listViewModel.clearAll()
        dependencies.activeChatStore.clear()
        newChatGeneration += 1
        Task { await refreshAllDataOnForeground() }
    }

    // MARK: - Progress Overlays

    private func applyOverlays<Content: View>(content: Content) -> some View {
        content
            .overlay {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("正在准备导出…")
                                .scaledFont(size: 16)
                                .foregroundStyle(.white)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if listViewModel.isDeletingBulk {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Deleting…")
                                .scaledFont(size: 16)
                                .foregroundStyle(.white)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
    }

    // MARK: - Drawer Toggle

    private func toggleDrawer() {
        if showDrawer {
            closeDrawerAnimated()
        } else {
            openDrawerAnimated()
        }
    }

    private func closeDrawer() {
        closeDrawerAnimated()
    }

    /// Animates the drawer to fully open, resets drag offset, triggers haptic + refresh.
    private func openDrawerAnimated() {
        // Dismiss keyboard immediately so it doesn't overlap the drawer
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showDrawer = true
            dragOffset = 0
        }
        Haptics.play(.light)
        Task {
            if usesDirectProvider {
                await listViewModel.refreshConversations()
            } else {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshConversations() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    group.addTask { await channelListVM.refreshChannels() }
                }
            }
        }
    }

    /// Animates the drawer to fully closed and resets drag offset.
    private func closeDrawerAnimated() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showDrawer = false
            dragOffset = 0
        }
    }

    // MARK: - File Browser Open/Close (right panel, mirrors drawer)

    /// Configures the terminal browser VM with the active chat's terminal server.
    private func configureTerminalBrowserIfNeeded() {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard vm.terminalEnabled, let server = vm.selectedTerminalServer else { return }
        if server.isLocalAlpine {
            terminalBrowserVM.configureLocalAlpine()
            return
        }
        guard let apiClient = dependencies.apiClient else { return }
        terminalBrowserVM.configure(apiClient: apiClient, serverId: server.id)
    }

    /// Animates the file browser to fully open.
    private func openFileBrowserAnimated() {
        configureTerminalBrowserIfNeeded()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showFileBrowser = true
            fileBrowserDragOffset = 0
        }
        // Explicitly load directory after opening to ensure files appear
        // (the .task modifier may have fired before configure() was called)
        terminalBrowserVM.refresh()
        Haptics.play(.light)
    }

    /// Animates the file browser to fully closed.
    private func closeFileBrowserAnimated() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showFileBrowser = false
            fileBrowserDragOffset = 0
        }
    }

    private var rightEdgeFileBrowserGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard isTerminalActiveInCurrentChat, !showFileBrowser, !showDrawer else { return }
                guard value.startLocation.x >= max(0, containerWidth - 24) else { return }

                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard abs(horizontal) > vertical, horizontal < 0 else { return }

                if !isDraggingFileBrowser {
                    configureTerminalBrowserIfNeeded()
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                isDraggingFileBrowser = true
                fileBrowserDragOffset = horizontal
            }
            .onEnded { value in
                guard isDraggingFileBrowser else { return }
                let horizontal = abs(value.translation.width)
                let velocity = abs(value.velocity.width)
                isDraggingFileBrowser = false
                if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                    openFileBrowserAnimated()
                } else {
                    closeFileBrowserAnimated()
                }
            }
    }

    private var desktopPetOverlay: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if desktopPetExpanded && !desktopPetShouldExpandUpward {
                desktopPetActions
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            desktopPetButton

            if desktopPetExpanded && desktopPetShouldExpandUpward {
                desktopPetActions
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var desktopPetShouldExpandUpward: Bool {
        let actionCount: CGFloat = 6
        let actionHeight: CGFloat = 46
        let actionSpacing: CGFloat = 8
        let estimatedActionsHeight = actionCount * actionHeight + max(0, actionCount - 1) * actionSpacing
        let petSize: CGFloat = 48
        let bottomPadding: CGFloat = 92
        let topBlockedHeight: CGFloat = 150
        let petCenterY = max(
            topBlockedHeight + petSize / 2,
            containerHeight - bottomPadding - petSize / 2 + currentDesktopPetOffset.height
        )
        let availableBelow = max(0, containerHeight - bottomPadding - petCenterY - petSize / 2)
        let availableAbove = max(0, petCenterY - topBlockedHeight - petSize / 2)

        // If the pet is already close to the top toolbar zone, always expand downward.
        if petCenterY < topBlockedHeight + estimatedActionsHeight + 16 {
            return false
        }

        // If the pet is close to the input bar, always expand upward.
        if availableBelow < estimatedActionsHeight + 16 {
            return true
        }

        if availableBelow >= estimatedActionsHeight {
            return false
        }
        if availableAbove >= estimatedActionsHeight {
            return true
        }
        return availableAbove > availableBelow
    }

    private var desktopPetActions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            desktopPetAction(title: "网页", icon: "globe") {
                postPetQuickAction(.openUIWebChat)
            }
            desktopPetAction(title: "摄像头", icon: "camera.fill") {
                postPetQuickAction(.openUICameraChat)
            }
            desktopPetAction(title: "照片", icon: "photo.fill") {
                postPetQuickAction(.openUIPhotosChat)
            }
            desktopPetAction(title: "文件", icon: "doc.fill") {
                postPetQuickAction(.openUIFileChat)
            }
            desktopPetAction(title: "新对话", icon: "square.and.pencil") {
                startNewChat()
                collapseDesktopPet()
            }
            desktopPetAction(title: "清空对话", icon: "trash") {
                clearCurrentChatFromPet()
            }
        }
    }

    private var desktopPetButton: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 48, height: 48)
            Circle()
                .fill(theme.cardBackground.opacity(theme.isDark ? 0.92 : 0.98))
                .frame(width: 40, height: 40)
            Circle()
                .strokeBorder(theme.brandPrimary.opacity(desktopPetExpanded ? 0.36 : 0.18), lineWidth: 1)
                .frame(width: 48, height: 48)
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        }
        .contentShape(Circle())
        .shadow(color: .black.opacity(theme.isDark ? 0.32 : 0.12), radius: 12, y: 5)
        .scaleEffect(desktopPetIsDragging ? 1.04 : 1)
        .accessibilityLabel("桌面宠物")
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    desktopPetDragOffset = value.translation
                    desktopPetIsDragging = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                    if desktopPetIsDragging && desktopPetExpanded {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                            desktopPetExpanded = false
                        }
                    }
                }
                .onEnded { value in
                    let translation = value.translation
                    let didDrag = abs(translation.width) > 6 || abs(translation.height) > 6
                    if didDrag {
                        let stored = CGSize(width: desktopPetOffsetX, height: desktopPetOffsetY)
                        let proposed = CGSize(
                            width: stored.width + translation.width,
                            height: stored.height + translation.height
                        )
                        let bounded = boundedDesktopPetOffset(proposed)
                        desktopPetOffsetX = Double(bounded.width)
                        desktopPetOffsetY = Double(bounded.height)
                        Haptics.play(.light)
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            desktopPetExpanded.toggle()
                        }
                        Haptics.play(.light)
                    }
                    desktopPetDragOffset = .zero
                    desktopPetIsDragging = false
                }
        )
    }

    private func desktopPetAction(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .scaledFont(size: 13, weight: .semibold)
                Image(systemName: icon)
                    .scaledFont(size: 13, weight: .semibold)
                    .frame(width: 18)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.45), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(theme.isDark ? 0.24 : 0.08), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func postPetQuickAction(_ name: Notification.Name) {
        NotificationCenter.default.post(name: .openUIDismissOverlays, object: nil)
        NotificationCenter.default.post(name: name, object: nil)
        collapseDesktopPet()
    }

    private func collapseDesktopPet() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            desktopPetExpanded = false
        }
        Haptics.play(.light)
    }

    private var currentDesktopPetOffset: CGSize {
        let stored = CGSize(width: desktopPetOffsetX, height: desktopPetOffsetY)
        return boundedDesktopPetOffset(
            CGSize(
                width: stored.width + desktopPetDragOffset.width,
                height: stored.height + desktopPetDragOffset.height
            )
        )
    }

    private func boundedDesktopPetOffset(_ proposed: CGSize) -> CGSize {
        let petSize: CGFloat = 48
        let horizontalMargin: CGFloat = 18
        let maxLeft = -max(0, containerWidth - petSize - horizontalMargin * 2)
        let maxRight: CGFloat = 10
        let usableHeight = max(containerHeight, 300)
        let maxUp = -max(0, usableHeight - petSize - 150)
        let maxDown: CGFloat = 10

        return CGSize(
            width: min(maxRight, max(maxLeft, proposed.width)),
            height: min(maxDown, max(maxUp, proposed.height))
        )
    }

    // MARK: - New Chat

    private func startNewChat() {
        // If we're already on the new-chat screen AND a transcription is in
        // progress, stay put — destroying the VM would silently discard the work.
        let alreadyOnNewChat = activeConversationId == nil && activeChannelId == nil
        let currentNewVM = dependencies.activeChatStore.viewModel(for: nil)
        if alreadyOnNewChat && currentNewVM.hasActiveTranscriptions {
            return
        }

        // If we're NOT already on the new-chat screen, just navigate there
        // without resetting the VM — the transcription can keep running.
        // Only remove + recreate the VM when there's no ongoing work.
        if !currentNewVM.hasActiveTranscriptions {
            dependencies.activeChatStore.remove(nil)
            newChatGeneration += 1
        }

        activeConversationId = nil
        activeChannelId = nil
        activeFolderWorkspaceId = nil
        // Reset terminal file browser state so it starts fresh in the new chat
        closeFileBrowserAnimated()
        terminalBrowserVM.reset()
        Haptics.play(.light)
    }

    private func clearCurrentChatFromPet() {
        collapseDesktopPet()
        if let conversationId = activeConversationId {
            dependencies.activeChatStore.remove(conversationId)
        } else {
            dependencies.activeChatStore.remove(nil)
        }
        activeConversationId = nil
        activeChannelId = nil
        activeFolderWorkspaceId = nil
        newChatGeneration += 1
        closeFileBrowserAnimated()
        terminalBrowserVM.reset()
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        Haptics.play(.medium)
    }

    // MARK: - Chat Content

    @ViewBuilder
    private var chatContent: some View {
        if let channelId = activeChannelId {
            // Show channel detail inline (same as how chats work)
            ChannelDetailView(channelId: channelId, channelListVM: channelListVM)
                .id("channel-\(channelId)")
                .transition(.opacity)
        } else if let conversationId = activeConversationId {
            ChatDetailView(
                conversationId: conversationId,
                viewModel: dependencies.activeChatStore.viewModel(for: conversationId),
                onNewChat: { startNewChat() }
            )
            .id(conversationId)
            .transition(.opacity)
        } else if let folderWorkspaceId = activeFolderWorkspaceId {
            // Folder workspace: new chat screen locked to this folder.
            // The ChatViewModel receives folder context so when the user
            // sends a message the chat is created inside this folder.
            let vm = dependencies.activeChatStore.viewModel(for: nil)
            let folder = listViewModel.folderViewModel.folders.first { $0.id == folderWorkspaceId }
                ?? listViewModel.folderViewModel.activeFolderDetail
            ChatDetailView(
                viewModel: vm,
                folderWorkspace: folder,
                onNewChat: { startNewChat() }
            )
            .id("folder-workspace-\(folderWorkspaceId)-\(newChatGeneration)")
            .transition(.opacity)
            .onAppear {
                // Set folder context on the VM so new chats are created in this folder
                let folderDetail = listViewModel.folderViewModel.activeFolderDetail
                vm.setFolderContext(
                    folderId: folderWorkspaceId,
                    systemPrompt: folderDetail?.systemPrompt
                        ?? folder?.systemPrompt,
                    modelIds: folderDetail?.modelIds
                        ?? folder?.modelIds
                        ?? []
                )
            }
        } else {
            ChatDetailView(
                viewModel: dependencies.activeChatStore.viewModel(for: nil),
                onNewChat: { startNewChat() }
            )
            .id("new-chat-\(newChatGeneration)")
            .transition(.opacity)
        }
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        MainModelSelectorLabel(
            conversationId: activeConversationId,
            activeChatStore: dependencies.activeChatStore,
            theme: theme
        )
    }

    // MARK: - Drawer Content

    private var drawerContent: some View {
        VStack(spacing: 0) {
            // Top bar: search or selection controls
            if listViewModel.isSelectionMode {
                selectionModeHeader
            } else {
                searchBar
            }

            // Conversation list grouped by time
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // ── PINNED MODELS SECTION (quick-switch shortcuts) ─
                    drawerPinnedModelsSection

                    // ── FOLDERS SECTION (always visible so user can create new folders) ─
                    let folderVM = listViewModel.folderViewModel
                    let foldersEnabled = !usesDirectProvider && dependencies.authViewModel.featurePermissions.folders
                    if foldersEnabled && !folderVM.featureDisabled {
                        drawerFoldersSection(folderVM: folderVM)
                    }

                    // ── DIVIDER between Folders & Channels ──────────────
                    let channelsEnabled = !usesDirectProvider && dependencies.authViewModel.featurePermissions.channels
                    if (foldersEnabled && !folderVM.featureDisabled && !folderVM.folders.isEmpty) || (channelsEnabled && !channelListVM.channels.isEmpty) {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // ── CHANNELS SECTION (shown only when enabled on server) ──
                    if channelsEnabled {  // swiftlint:disable:this opening_brace
                    VStack(alignment: .leading, spacing: 0) {
                        // Collapsible header
                        Button {
                            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                channelsExpanded.toggle()
                            }
                            Haptics.play(.light)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.down")
                                    .scaledFont(size: 8, weight: .bold, context: .list)
                                    .foregroundStyle(theme.textTertiary)
                                    .rotationEffect(.degrees(channelsExpanded ? 0 : -90))
                                    .animation(.easeInOut(duration: AnimDuration.fast), value: channelsExpanded)

                                Image(systemName: "bubble.left.and.bubble.right")
                                    .scaledFont(size: 10, weight: .semibold, context: .list)
                                    .foregroundStyle(theme.textTertiary)
                                Text("Channels")
                                    .scaledFont(size: 12, weight: .medium, context: .list)
                                    .fontWeight(.bold)
                                    .foregroundStyle(theme.textTertiary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                Spacer()

                                // Create new channel directly (always visible)
                                Button {
                                    closeDrawer()
                                    showCreateChannel = true
                                } label: {
                                    Image(systemName: "plus.bubble")
                                        .scaledFont(size: 13, context: .list)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if channelsExpanded {
                            if channelListVM.channels.isEmpty {
                                Text("No channels yet")
                                    .scaledFont(size: 13, context: .list)
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, 4)
                            } else {
                                // DMs first
                                if !channelListVM.dmChannels.isEmpty {
                                    drawerChannelGroupLabel("Direct Messages", icon: "person.crop.circle")
                                    ForEach(channelListVM.dmChannels) { channel in
                                        drawerChannelRow(channel)
                                    }
                                }
                                // Groups
                                if !channelListVM.groupChannels.isEmpty {
                                    drawerChannelGroupLabel("Groups", icon: "person.3")
                                    ForEach(channelListVM.groupChannels) { channel in
                                        drawerChannelRow(channel)
                                    }
                                }
                                // Standard channels
                                if !channelListVM.standardChannels.isEmpty {
                                    drawerChannelGroupLabel("Channels", icon: "number")
                                    ForEach(channelListVM.standardChannels) { channel in
                                        drawerChannelRow(channel)
                                    }
                                }
                            }
                        }
                    }
                    } // end if channelsEnabled

                    // ── DIVIDER between Channels & Chats ──────────────
                    if channelsEnabled && !channelListVM.channels.isEmpty {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // ── CHATS SECTION (entire section is a drop zone) ─
                    let hasAnyChats = !listViewModel.pinnedConversations.isEmpty
                        || !listViewModel.groupedConversations.isEmpty

                    if hasAnyChats || !folderVM.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            // Collapsible header (also acts as drop zone indicator)
                            Button {
                                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                    chatsExpanded.toggle()
                                }
                                Haptics.play(.light)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.down")
                                        .scaledFont(size: 8, weight: .bold, context: .list)
                                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                                        .rotationEffect(.degrees(chatsExpanded ? 0 : -90))
                                        .animation(.easeInOut(duration: AnimDuration.fast), value: chatsExpanded)

                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                        .scaledFont(size: 10, weight: .semibold, context: .list)
                                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                                    Text("Chats")
                                        .scaledFont(size: 12, weight: .medium, context: .list)
                                        .fontWeight(.bold)
                                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                    if drawerChatsDropActive {
                                        Text("Drop here")
                                            .scaledFont(size: 12, weight: .medium, context: .list)
                                            .foregroundStyle(theme.brandPrimary)
                                            .transition(.opacity)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.top, Spacing.sm)
                                .padding(.bottom, Spacing.xs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if chatsExpanded {
                                // LazyVStack so only visible rows are created.
                                // Section headers are inlined as direct children
                                // so they don't prevent lazy row creation.
                                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                                    // ── Pinned sub-section ────────────────────
                                    if !listViewModel.pinnedConversations.isEmpty {
                                        // Section header
                                        drawerSubSectionHeader(title: "Pinned", sectionKey: "Pinned")

                                        // Rows — only rendered when section is expanded
                                        if !collapsedSections.contains("Pinned") {
                                            ForEach(listViewModel.pinnedConversations) { conversation in
                                                drawerConversationRow(conversation)
                                                    .frame(minHeight: 36)
                                            }
                                        }
                                    }

                                    // ── Time-grouped sub-sections ─────────────
                                    ForEach(listViewModel.groupedConversations, id: \.0) { group in
                                        let sectionKey = group.0
                                        let isCollapsed = collapsedSections.contains(sectionKey)

                                        // Section header
                                        drawerSubSectionHeader(
                                            title: sectionKey,
                                            count: group.1.count,
                                            sectionKey: sectionKey
                                        )

                                        // Rows — only rendered when section is expanded
                                        if !isCollapsed {
                                            ForEach(group.1) { conversation in
                                                drawerConversationRow(conversation)
                                                    .frame(minHeight: 36)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .background(
                            drawerChatsDropActive
                                ? theme.brandPrimary.opacity(0.06)
                                : Color.clear
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .stroke(theme.brandPrimary, lineWidth: drawerChatsDropActive ? 1.5 : 0)
                                .padding(.horizontal, 2)
                        )
                        .animation(.easeInOut(duration: AnimDuration.fast), value: drawerChatsDropActive)
                        .dropDestination(for: DraggableChat.self) { items, _ in
                            guard let item = items.first,
                                  item.currentFolderId != nil else { return false }
                            let chatId = item.conversationId
                            let folderChats = folderVM.folders.flatMap(\.chats)
                            let conversation = folderChats.first(where: { $0.id == chatId })
                                ?? listViewModel.conversations.first(where: { $0.id == chatId })
                            guard let conversation else { return false }

                            withAnimation {
                                drawerChatsDropActive = false
                                folderVM.dragCompleted()
                            }
                            // Update folderId locally — add to conversations list if missing
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                                listViewModel.conversations[idx].folderId = nil
                            } else {
                                var conv = conversation
                                conv.folderId = nil
                                listViewModel.conversations.insert(conv, at: 0)
                            }
                            Task { await folderVM.moveChat(conversation: conversation, to: nil) }
                            return true
                        } isTargeted: { isTargeted in
                            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                drawerChatsDropActive = isTargeted
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.md)
            }

            if listViewModel.isSelectionMode {
                selectionModeBottomBar
            } else {
                drawerBottomBar
            }
        }
        .background(theme.background)
    }

    // MARK: - Selection Mode Header

    private var selectionModeHeader: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    listViewModel.exitSelectionMode()
                }
            } label: {
                Text("Cancel")
                    .scaledFont(size: 16, context: .list)
                    .foregroundStyle(theme.brandPrimary)
            }

            Spacer()

            Text("\(listViewModel.selectedCount) selected")
                .scaledFont(size: 14, weight: .medium, context: .list)
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            Button {
                if listViewModel.selectedCount == listViewModel.filteredConversations.count {
                    listViewModel.selectedConversationIds.removeAll()
                } else {
                    listViewModel.selectAll()
                }
            } label: {
                Text(listViewModel.selectedCount == listViewModel.filteredConversations.count ? "Deselect All" : "Select All")
                    .scaledFont(size: 12, weight: .medium, context: .list)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14, context: .list)
                .foregroundStyle(theme.textTertiary)

            TextField("Search conversations...", text: $listViewModel.searchText)
                .scaledFont(size: 16, context: .list)
                .foregroundStyle(theme.textPrimary)

            if !listViewModel.searchText.isEmpty {
                Button {
                    listViewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14, context: .list)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            if !listViewModel.conversations.isEmpty {
                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            listViewModel.toggleSelectionMode()
                        }
                    } label: {
                        Label("Select Chats", systemImage: "checkmark.circle")
                    }

                    Button {
                        listViewModel.showArchiveAllConfirmation = true
                    } label: {
                        Label("Archive All Chats", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Chats", systemImage: "trash")
                    }

                    if !usesDirectProvider {
                        Divider()

                        Button {
                            closeDrawer()
                            showArchivedChats = true
                        } label: {
                            Label("Archived Chats", systemImage: "archivebox")
                        }

                        Button {
                            closeDrawer()
                            showSharedChats = true
                        } label: {
                            Label("Shared Chats", systemImage: "link.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .scaledFont(size: 16, weight: .medium, context: .list)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }

            Button {
                closeDrawer()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .scaledFont(size: 16, weight: .medium, context: .list)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Drawer Section

    @ViewBuilder
    private func drawerSection<Content: View>(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 10, weight: .semibold, context: .list)
                    .foregroundStyle(theme.textTertiary)

                Text(title)
                    .scaledFont(size: 14, weight: .medium, context: .list)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textSecondary)

                if let count {
                    Text("\(count)")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.surfaceContainer)
                        .clipShape(Capsule())
                }

                Spacer()

                if systemImage == "folder" {
                    Button {} label: {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(size: 14, context: .list)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            content()
        }
    }

    // MARK: - Drawer Pinned Models Section

    /// Shows pinned models as quick-switch shortcuts in the sidebar,
    /// matching the web UI's "Models" section above folders.
    @ViewBuilder
    private var drawerPinnedModelsSection: some View {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        let pinnedIds = vm.pinnedModelIds
        let models = vm.availableModels
        let pinnedModels = pinnedIds.compactMap { id in models.first(where: { $0.id == id }) }

        if !pinnedModels.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Section header
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .scaledFont(size: 10, weight: .semibold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                    Text("Models")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                // Pinned model rows
                ForEach(pinnedModels) { model in
                    let isSelected = model.id == vm.selectedModelId
                    Button {
                        let modelId = model.id
                        startNewChat()
                        let newVM = dependencies.activeChatStore.viewModel(for: nil)
                        newVM.selectModel(modelId)
                        closeDrawer()
                    } label: {
                        HStack(spacing: 8) {
                            ModelAvatar(
                                size: 22,
                                imageURL: vm.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: vm.serverAuthToken
                            )
                            Text(model.shortName)
                                .scaledFont(size: 14, context: .list)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .scaledFont(size: 11, weight: .semibold, context: .list)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 7)
                        .background(isSelected ? theme.brandPrimary.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            vm.togglePinModel(model.id)
                            Haptics.play(.medium)
                        } label: {
                            Label("Unpin", systemImage: "pin.slash")
                        }
                    }
                }
            }

            // Divider below models
            Rectangle()
                .fill(theme.textTertiary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
        }
    }

    // MARK: - Drawer Folders Section

    @ViewBuilder
    private func drawerFoldersSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header with collapse toggle + "New Folder" button
            Button {
                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                    foldersExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(foldersExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: AnimDuration.fast), value: foldersExpanded)

                    Image(systemName: "folder")
                        .scaledFont(size: 10, weight: .semibold, context: .list)
                        .foregroundStyle(theme.textTertiary)

                    Text("Folders")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()

                    Button {
                        showCreateFolderSheet = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(size: 13, context: .list)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Folder rows — use rootFolders (tree with childFolders populated)
            if foldersExpanded {
                ForEach(folderVM.rootFolders) { folder in
                    DrawerFolderRow(
                        folder: folder,
                        folderVM: folderVM,
                        allConversations: listViewModel.conversations,
                        activeConversationId: activeConversationId,
                        activeFolderWorkspaceId: activeFolderWorkspaceId,
                        onSelectChat: { chatId in
                            activeConversationId = chatId
                            activeFolderWorkspaceId = nil
                            SharedDataService.shared.saveLastActiveConversationId(chatId)
                            closeDrawer()
                        },
                        onSelectFolder: { folderId in
                            Task { await folderVM.setActiveFolder(folderId) }
                            dependencies.activeChatStore.remove(nil)
                            newChatGeneration += 1
                            activeFolderWorkspaceId = folderId
                            activeConversationId = nil
                            activeChannelId = nil
                            closeDrawer()
                        },
                        onChatMoved: { chatId, targetFolderId in
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                                listViewModel.conversations[idx].folderId = targetFolderId
                            } else if targetFolderId == nil {
                                let folderChats = folderVM.folders.flatMap(\.chats)
                                if var conv = folderChats.first(where: { $0.id == chatId }) {
                                    conv.folderId = nil
                                    listViewModel.conversations.insert(conv, at: 0)
                                }
                            }
                        },
                        onDeleteChat: { chatId in
                            Task {
                                await listViewModel.deleteConversation(id: chatId)
                                for fIdx in folderVM.folders.indices {
                                    folderVM.folders[fIdx].chats.removeAll { $0.id == chatId }
                                }
                                if activeConversationId == chatId {
                                    startNewChat()
                                }
                            }
                        },
                        onTogglePin: { conversation in
                            Task { await listViewModel.togglePin(conversation: conversation) }
                        }
                    )
                    .padding(.horizontal, Spacing.sm)
                }
            }
        }
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.folders.map(\.id))
    }

    // MARK: - Drawer Sub-Section Header (for LazyVStack chat groups)

    /// Inline collapsible header used inside the `LazyVStack` for chat time-groups.
    /// Because the rows are direct children of `LazyVStack`, we cannot use
    /// `CollapsibleDrawerSection` (which wraps content in a `VStack`). Instead,
    /// each header and its rows are all flat siblings of the `LazyVStack`.
    @ViewBuilder
    private func drawerSubSectionHeader(title: String, count: Int? = nil, sectionKey: String) -> some View {
        let isCollapsed = collapsedSections.contains(sectionKey)
        Button {
            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                if isCollapsed {
                    collapsedSections.remove(sectionKey)
                } else {
                    collapsedSections.insert(sectionKey)
                }
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 8, weight: .bold, context: .list)
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.easeInOut(duration: AnimDuration.fast), value: isCollapsed)

                Text(title)
                    .scaledFont(size: 12, weight: .medium, context: .list)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if let count {
                    Text("\(count)")
                        .scaledFont(size: 10, weight: .medium, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.surfaceContainer)
                        .clipShape(Capsule())
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Drawer Channel Helpers

    /// Small sub-group label (e.g. "Direct Messages", "Groups", "Channels") inside the channels section.
    @ViewBuilder
    private func drawerChannelGroupLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 9, weight: .medium, context: .list)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
            Text(title)
                .scaledFont(size: 10, weight: .medium, context: .list)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// A single channel row in the drawer sidebar.
    @ViewBuilder
    private func drawerChannelRow(_ channel: Channel) -> some View {
        Button {
            activeChannelId = channel.id
            activeConversationId = nil
            closeDrawer()
        } label: {
            HStack(spacing: 6) {
                // DM: show participant avatar; others: show icon
                if channel.type == .dm, let participant = channel.dmParticipants.first {
                    UserAvatar(
                        size: 22,
                        imageURL: participant.resolveAvatarURL(serverBaseURL: dependencies.apiClient?.baseURL ?? ""),
                        name: participant.displayName,
                        authToken: dependencies.apiClient?.network.authToken
                    )
                } else {
                    Image(systemName: channel.sidebarIcon)
                        .scaledFont(size: 11, context: .list)
                        .foregroundStyle(activeChannelId == channel.id ? theme.brandPrimary : theme.textTertiary)
                }
                Text(channel.type == .dm
                    ? (channel.dmParticipants.first?.displayName ?? channel.displayName)
                    : channel.displayName)
                    .scaledFont(size: 14, context: .list)
                    .fontWeight(activeChannelId == channel.id || channel.unreadCount > 0 ? .semibold : .regular)
                    .foregroundStyle(activeChannelId == channel.id ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if channel.unreadCount > 0 {
                    Text("\(channel.unreadCount)")
                        .scaledFont(size: 11, weight: .bold, context: .list)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.brandPrimary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 7)
            .background(
                activeChannelId == channel.id
                    ? theme.brandPrimary.opacity(0.08)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if channel.type == .dm {
                Button {
                    channelListVM.hideDM(channelId: channel.id)
                    Haptics.play(.light)
                } label: {
                    Label("Hide Conversation", systemImage: "eye.slash")
                }
            } else {
                Button(role: .destructive) {
                    deletingChannelId = channel.id
                } label: {
                    Label("Delete Channel", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Drawer Conversation Row

    private func drawerConversationRow(_ conversation: Conversation) -> some View {
        Group {
            if listViewModel.isSelectionMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        listViewModel.toggleSelection(for: conversation.id)
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: listViewModel.isSelected(conversation.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                        )
                        .scaledFont(size: 18, context: .list)
                        .foregroundStyle(
                            listViewModel.isSelected(conversation.id)
                                ? theme.brandPrimary
                                : theme.textTertiary
                        )

                        Text(conversation.title)
                            .scaledFont(size: 14, context: .list)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        listViewModel.isSelected(conversation.id)
                            ? theme.brandPrimary.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    activeConversationId = conversation.id
                    activeChannelId = nil  // Clear channel when opening a chat
                    activeFolderWorkspaceId = nil  // Clear folder highlight when opening a regular chat
                    SharedDataService.shared.saveLastActiveConversationId(conversation.id)
                    closeDrawer()
                } label: {
                    HStack {
                        Text(conversation.title)
                            .scaledFont(size: 14, context: .list)
                            .fontWeight(activeConversationId == conversation.id ? .semibold : .regular)
                            .foregroundStyle(
                                activeConversationId == conversation.id
                                    ? theme.textPrimary
                                    : theme.textSecondary
                            )
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        activeConversationId == conversation.id
                            ? theme.brandPrimary.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Make draggable into a folder
                .draggable(DraggableChat(
                    conversationId: conversation.id,
                    currentFolderId: conversation.folderId
                )) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "bubble.left").scaledFont(size: 12, context: .list)
                        Text(conversation.title)
                            .scaledFont(size: 12, weight: .medium, context: .list)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    // Share is an Iexa native server server feature.
                    if !usesDirectProvider {
                        Button {
                            sharingConversation = conversation
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }

                    // Download submenu (matching WebUI)
                    Menu {
                        Button {
                            Task { await exportChat(conversation, format: .json) }
                        } label: {
                            Label("Export chat (.json)", systemImage: "doc")
                        }
                        Button {
                            Task { await exportChat(conversation, format: .txt) }
                        } label: {
                            Label("Plain text (.txt)", systemImage: "doc.plaintext")
                        }
                        if !usesDirectProvider {
                            Button {
                                Task { await exportChat(conversation, format: .pdf) }
                            } label: {
                                Label("PDF document (.pdf)", systemImage: "doc.richtext")
                            }
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }

                    // Rename
                    Button {
                        renamingConversation = conversation
                        renameText = conversation.title
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    // Pin
                    Button {
                        Task { await listViewModel.togglePin(conversation: conversation) }
                    } label: {
                        Label(
                            conversation.pinned ? "Unpin" : "Pin",
                            systemImage: conversation.pinned ? "pin.slash" : "pin"
                        )
                    }

                    // Clone uses the Iexa native server chats API.
                    if !usesDirectProvider {
                        Button {
                            Task {
                                guard let manager = dependencies.conversationManager else { return }
                                let cloned = try? await manager.cloneConversation(id: conversation.id)
                                if let cloned {
                                    await listViewModel.refreshConversations()
                                    activeConversationId = cloned.id
                                    closeDrawer()
                                }
                            }
                        } label: {
                            Label("Clone", systemImage: "doc.on.doc")
                        }
                    }

                    // Archive
                    Button {
                        Task {
                            await listViewModel.toggleArchive(conversation: conversation)
                            if !conversation.archived && activeConversationId == conversation.id {
                                activeConversationId = nil
                            }
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }

                    // Move to folder submenu
                    let folders = listViewModel.folderViewModel.folders
                    if !folders.isEmpty {
                        Menu("Move to Folder") {
                            if conversation.folderId != nil {
                                Button {
                                    let conv = conversation
                                    Task {
                                        await listViewModel.folderViewModel.moveChat(conversation: conv, to: nil)
                                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            listViewModel.conversations[idx].folderId = nil
                                        }
                                    }
                                } label: {
                                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                                }
                            }
                            ForEach(folders) { folder in
                                Button {
                                    let conv = conversation
                                    let folderId = folder.id
                                    Task {
                                        await listViewModel.folderViewModel.moveChat(conversation: conv, to: folderId)
                                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            listViewModel.conversations[idx].folderId = folderId
                                        }
                                    }
                                } label: {
                                    Label(folder.name, systemImage: "folder")
                                }
                                .disabled(folder.id == conversation.folderId)
                            }
                        }
                    }

                    Divider()

                    // Delete
                    Button(role: .destructive) {
                        deletingConversation = conversation
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Selection Mode Bottom Bar

    private var selectionModeBottomBar: some View {
        Button(role: .destructive) {
            showDeleteSelectedConfirmation = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "trash")
                Text("Delete Selected (\(listViewModel.selectedCount))")
            }
            .scaledFont(size: 14, weight: .medium, context: .list)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(
                listViewModel.selectedCount > 0
                    ? Color.red
                    : Color.red.opacity(0.3)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .disabled(listViewModel.selectedCount == 0)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .background(theme.surfaceContainer.opacity(0.3))
    }

    // MARK: - Drawer Bottom Bar

    private var drawerBottomBar: some View {
        VStack(spacing: 0) {
            // Subtle top separator
            Rectangle()
                .fill(theme.textTertiary.opacity(0.12))
                .frame(height: 0.5)

            HStack(spacing: Spacing.sm) {
                // User avatar + full name — tap → Settings, long-press → Account Picker
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatar(
                            size: 32,
                            imageURL: sidebarUserAvatarURL,
                            name: dependencies.authViewModel.currentUser?.displayName ?? "User",
                            authToken: dependencies.apiClient?.network.authToken,
                            dataURIString: sidebarUserAvatarDataURI
                        )

                    }

                    Text(dependencies.authViewModel.currentUser?.displayName ?? "User")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    Haptics.play(.medium)
                    dependencies.authViewModel.showAccountPicker = true
                }
                .simultaneousGesture(TapGesture().onEnded {
                    closeDrawer()
                    showSettings = true
                })

                Spacer()

                // New Chat — primary action, always visible
                Button {
                    closeDrawer()
                    startNewChat()
                } label: {
                    NewConversationIcon(size: 21)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("新对话")

                // More menu — secondary actions tucked away cleanly
                Menu {
                    if usesDirectProvider || dependencies.authViewModel.featurePermissions.memories {
                        Button {
                            closeDrawer()
                            showMemories = true
                        } label: {
                            Label("记忆", systemImage: "brain.head.profile")
                        }
                    }
                    if !usesDirectProvider && dependencies.authViewModel.hasAnyWorkspaceAccess {
                        Button {
                            showWorkspace = true
                        } label: {
                            Label("工作区", systemImage: "square.grid.2x2")
                        }
                    }

                    if !usesDirectProvider && dependencies.authViewModel.featurePermissions.notes {
                        Button {
                            closeDrawer()
                            showNotes = true
                        } label: {
                            Label("Notes", systemImage: "note.text")
                        }
                    }

                    Button {
                        closeDrawer()
                        showWeather = true
                    } label: {
                        Label("天气", systemImage: "cloud.sun")
                    }

                    if usesDirectProvider || dependencies.authViewModel.featurePermissions.calendar {
                        Button {
                            closeDrawer()
                            showCalendar = true
                        } label: {
                            Label("日历", systemImage: "calendar")
                        }
                    }

                    Button {
                        closeDrawer()
                        showLocalWorkspaceBrowser = true
                    } label: {
                        Label("浏览文件", systemImage: "folder")
                    }

                    Button {
                        closeDrawer()
                        showLocalAlpineTerminal = true
                    } label: {
                        Label("终端功能", systemImage: "terminal")
                    }

                    if !usesDirectProvider && dependencies.authViewModel.featurePermissions.automations {
                        Button {
                            closeDrawer()
                            showAutomations = true
                        } label: {
                            Label("Automations", systemImage: "clock.arrow.circlepath")
                        }
                    }

                    Divider()

                    Button {
                        closeDrawer()
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    if dependencies.authViewModel.currentUser?.role == .admin {
                        Button {
                            closeDrawer()
                            showAdminConsole = true
                        } label: {
                            Label("Admin Console", systemImage: "shield.lefthalf.filled")
                        }
                    }
                } label: {
                    SettingsGearIcon()
                        .scaledFont(size: 18, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
        }
        .background(theme.background)
    }

    // MARK: - Title Generation

    private func generateTitleForRename(_ conversation: Conversation) async {
        guard let api = dependencies.apiClient,
              let manager = dependencies.conversationManager else { return }

        isGeneratingTitle = true
        do {
            let fullConv = try await manager.fetchConversation(id: conversation.id)
            let messages: [[String: Any]] = fullConv.messages.map { msg in
                ["role": msg.role.rawValue, "content": msg.content]
            }
            let model = fullConv.model ?? dependencies.activeChatStore.cachedSelectedModelId ?? ""
            if let title = try await api.generateConversationTitle(model: model, messages: messages) {
                renameText = title
            }
        } catch {
            // Silently fail — keep current text
        }
        isGeneratingTitle = false
    }

    // MARK: - Chat Export

    enum ExportFormat { case json, txt, pdf }

    private func exportChat(_ conversation: Conversation, format: ExportFormat) async {
        guard let manager = dependencies.conversationManager else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let fullConversation = try await manager.fetchConversation(id: conversation.id)
            let title = fullConversation.title
            let messages = fullConversation.messages
            let tmpDir = FileManager.default.temporaryDirectory

            switch format {
            case .json:
                let payload: [[String: Any]] = messages.map { msg in
                    ["role": msg.role.rawValue, "content": msg.content, "timestamp": msg.timestamp.timeIntervalSince1970]
                }
                let wrapper: [String: Any] = ["title": title, "messages": payload]
                let data = try JSONSerialization.data(withJSONObject: wrapper, options: .prettyPrinted)
                let url = tmpDir.appendingPathComponent("\(title).json")
                try data.write(to: url)
                exportFileURL = url
                showExportShareSheet = true

            case .txt:
                var text = "# \(title)\n\n"
                for msg in messages {
                    let role = msg.role == .user ? "User" : (msg.role == .assistant ? "Assistant" : msg.role.rawValue)
                    text += "[\(role)]\n\(msg.content)\n\n"
                }
                let url = tmpDir.appendingPathComponent("\(title).txt")
                try text.write(to: url, atomically: true, encoding: .utf8)
                exportFileURL = url
                showExportShareSheet = true

            case .pdf:
                guard let api = dependencies.apiClient else { return }
                // Use the server's raw message format for PDF generation.
                // The API fetches the full chat JSON and passes native messages
                // to the PDF renderer, avoiding any format mismatches.
                let pdfData = try await api.downloadChatAsPDF(chatId: fullConversation.id)
                let url = tmpDir.appendingPathComponent("\(title).pdf")
                try pdfData.write(to: url)
                exportFileURL = url
                showExportShareSheet = true
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Foreground Refresh

    private func refreshAllDataOnForeground() async {
        if usesDirectProvider {
            await listViewModel.refreshIfStale()
            dependencies.updateWidgetData(conversations: listViewModel.conversations)
            return
        }

        // Use connect() without force so an already-in-progress connection
        // is NOT cancelled. connect(force:true) calls disconnectInternal()
        // which cancels the current URLSessionWebSocketTask, causing
        // "Receive error: cancelled" → handleDisconnect → autoReconnect →
        // connect(force:true) → infinite reconnect loop.
        if let socket = dependencies.socketService, !socket.isConnected, !socket.isConnecting {
            socket.connect()
        }

        // Refresh both conversations and folders in parallel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await listViewModel.refreshIfStale() }
            group.addTask { await listViewModel.folderViewModel.refreshFolders() }
        }

        // Do NOT call loadConversation() here — it sets isLoadingConversation=true
        // which tears down the entire message list and replaces it with skeleton
        // placeholders, destroying scroll position and causing the avatar flash.
        //
        // ChatViewModel.startForegroundSyncListener() (registered during load())
        // already handles foreground sync via syncWithServer(), which uses
        // adoptServerMessages() for in-place surgical updates — no view recreation,
        // no scroll jump, no flash.
        //
        // Similarly do NOT reload models/tools — they're loaded once on init and
        // refreshed lazily before each send via refreshSelectedModelMetadata().

        dependencies.updateWidgetData(conversations: listViewModel.conversations)
    }

    // MARK: - Socket Reconnect Handler

    private func registerSocketReconnectHandler() {
        guard !hasRegisteredSocketHandlers else { return }
        hasRegisteredSocketHandlers = true

        dependencies.socketService?.onReconnect = { [self] in
            Task { @MainActor in
                // Refresh both conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                }
                // Use syncWithServer() instead of loadConversation() —
                // syncWithServer() does in-place updates via adoptServerMessages()
                // and does NOT set isLoadingConversation=true, so the message list
                // stays stable (no flash, no scroll jump).
                if let activeId = activeConversationId {
                    let vm = dependencies.activeChatStore.viewModel(for: activeId)
                    if !vm.isStreaming {
                        await vm.syncWithServer()
                    }
                }
            }
        }

        dependencies.socketService?.onConnect = { [self] in
            Task { @MainActor in
                // Refresh both conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                }
            }
        }
    }
}

// MARK: - Performance Window

struct PerformanceWindowView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @StateObject private var monitor = PerformanceWindowMonitor()
    @AppStorage("performanceWindowOffsetX") private var storedOffsetX = 0.0
    @AppStorage("performanceWindowOffsetY") private var storedOffsetY = 0.0
    @AppStorage("performanceWindowShowCPU") private var showCPU = true
    @AppStorage("performanceWindowShowFPS") private var showFPS = true
    @AppStorage("performanceWindowShowLatency") private var showLatency = true
    @AppStorage("performanceWindowShowNetworkSpeed") private var showNetworkSpeed = true
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    let topInset: CGFloat
    let trailingInset: CGFloat
    let bottomInset: CGFloat
    let leadingInset: CGFloat

    init(
        topInset: CGFloat = 58,
        trailingInset: CGFloat = 12,
        bottomInset: CGFloat = 116,
        leadingInset: CGFloat = 12
    ) {
        self.topInset = topInset
        self.trailingInset = trailingInset
        self.bottomInset = bottomInset
        self.leadingInset = leadingInset
    }

    var body: some View {
        Group {
            if hasVisibleMetrics {
                GeometryReader { proxy in
                    ZStack(alignment: .topTrailing) {
                        hudBody
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .scaleEffect(isDragging ? 1.035 : 1)
                            .offset(currentOffset(in: proxy.size))
                            .padding(.top, topInset)
                            .padding(.trailing, trailingInset)
                            .gesture(dragGesture(in: proxy.size))
                            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isDragging)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
                }
            }
        }
    }

    private var hudBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showCPU {
                metricRow(label: "CPU", value: monitor.cpuText, tint: cpuTint)
            }
            if showFPS {
                metricRow(label: "FPS", value: "\(monitor.fps)", tint: fpsTint)
            }
            if showLatency {
                metricRow(label: "PING", value: monitor.latencyText, tint: latencyTint)
            }
            if showNetworkSpeed {
                metricRow(label: "NET", value: monitor.networkSpeedText, tint: networkTint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 112)
        .iexaToolbarGlass(cornerRadius: 14, compact: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear {
            monitor.configureNetworkTarget(activeNetworkProbeBaseURL)
            monitor.start()
        }
        .onChange(of: activeNetworkProbeBaseURL) { _, newValue in
            monitor.configureNetworkTarget(newValue)
        }
        .onDisappear { monitor.stop() }
    }

    private var accessibilityText: String {
        var parts = ["性能窗口"]
        if showCPU { parts.append("CPU \(monitor.cpuText)") }
        if showFPS { parts.append("FPS \(monitor.fps)") }
        if showLatency { parts.append("网络延迟 \(monitor.latencyText)") }
        if showNetworkSpeed { parts.append("网络速度 \(monitor.networkSpeedText)") }
        return parts.joined(separator: " ")
    }

    private var hasVisibleMetrics: Bool {
        showCPU || showFPS || showLatency || showNetworkSpeed
    }

    private var visibleMetricCount: Int {
        [showCPU, showFPS, showLatency, showNetworkSpeed].filter { $0 }.count
    }

    private var activeNetworkProbeBaseURL: String? {
        (showLatency || showNetworkSpeed) ? networkProbeBaseURL : nil
    }

    private var networkProbeBaseURL: String? {
        dependencies.apiClient?.baseURL ?? dependencies.serverConfigStore.activeServer?.url
    }

    private var cpuTint: Color {
        switch monitor.cpuUsage {
        case 0..<45: .green
        case 45..<80: .orange
        default: .red
        }
    }

    private var fpsTint: Color {
        monitor.fps >= 50 ? .green : (monitor.fps >= 30 ? .orange : .red)
    }

    private var latencyTint: Color {
        guard let latency = monitor.latencyMS else {
            return monitor.networkIsReachable ? .secondary : .red
        }
        switch latency {
        case 0..<250: return .green
        case 250..<800: return .orange
        default: return .red
        }
    }

    private var networkTint: Color {
        guard monitor.networkIsReachable else { return .red }
        guard let bytesPerSecond = monitor.networkBytesPerSecond else { return .secondary }
        switch bytesPerSecond {
        case 0..<32_000: return .orange
        default: return .green
        }
    }

    private func metricRow(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)

            Text(label)
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 30, alignment: .leading)

            Text(value)
                .scaledFont(size: 11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .lineLimit(1)
    }

    private func dragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = value.translation
                isDragging = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
            }
            .onEnded { value in
                let didDrag = abs(value.translation.width) > 4 || abs(value.translation.height) > 4
                let stored = CGSize(width: storedOffsetX, height: storedOffsetY)
                let proposed = CGSize(
                    width: stored.width + value.translation.width,
                    height: stored.height + value.translation.height
                )
                let bounded = boundedOffset(proposed, in: containerSize)
                storedOffsetX = Double(bounded.width)
                storedOffsetY = Double(bounded.height)

                dragOffset = .zero
                isDragging = false

                if didDrag {
                    Haptics.play(.light)
                }
            }
    }

    private func currentOffset(in containerSize: CGSize) -> CGSize {
        let stored = CGSize(width: storedOffsetX, height: storedOffsetY)
        let proposed = CGSize(
            width: stored.width + dragOffset.width,
            height: stored.height + dragOffset.height
        )
        return boundedOffset(proposed, in: containerSize)
    }

    private func boundedOffset(_ proposed: CGSize, in containerSize: CGSize) -> CGSize {
        let estimatedHUDSize = CGSize(
            width: 122,
            height: max(40, CGFloat(visibleMetricCount) * 18 + 22)
        )
        let maxLeft = -max(0, containerSize.width - estimatedHUDSize.width - leadingInset - trailingInset)
        let maxRight: CGFloat = 0
        let maxUp = -max(0, topInset - leadingInset)
        let maxDown = max(0, containerSize.height - estimatedHUDSize.height - topInset - bottomInset)

        return CGSize(
            width: min(maxRight, max(maxLeft, proposed.width)),
            height: min(maxDown, max(maxUp, proposed.height))
        )
    }
}

private final class PerformanceWindowMonitor: NSObject, ObservableObject {
    @Published private(set) var fps = 0
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var latencyMS: Int?
    @Published private(set) var networkBytesPerSecond: Double?
    @Published private(set) var networkIsReachable = false
    @Published private(set) var networkIsProbing = false

    private var displayLink: CADisplayLink?
    private var cpuTimer: Timer?
    private var networkTimer: Timer?
    private var networkDataTask: URLSessionDataTask?
    private var networkProbeBaseURL: URL?
    private let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()
    private var frameCount = 0
    private var lastFPSUpdate: CFTimeInterval = 0
    private var isRunning = false

    var cpuText: String {
        "\(Int(cpuUsage.rounded()))%"
    }

    var latencyText: String {
        if let latencyMS {
            return "\(latencyMS)ms"
        }
        return networkIsProbing ? "..." : "—"
    }

    var networkSpeedText: String {
        guard networkIsReachable else {
            return networkIsProbing ? "..." : "离线"
        }
        guard let networkBytesPerSecond, networkBytesPerSecond > 0 else {
            return "—"
        }
        if networkBytesPerSecond >= 1_048_576 {
            return String(format: "%.1fM/s", networkBytesPerSecond / 1_048_576)
        }
        if networkBytesPerSecond >= 1024 {
            return "\(Int(networkBytesPerSecond / 1024))K/s"
        }
        return "\(Int(networkBytesPerSecond))B/s"
    }

    func configureNetworkTarget(_ baseURLString: String?) {
        let newURL = Self.normalizedNetworkProbeBaseURL(from: baseURLString)
        guard newURL != networkProbeBaseURL else { return }
        networkProbeBaseURL = newURL
        networkDataTask?.cancel()
        networkDataTask = nil
        latencyMS = nil
        networkBytesPerSecond = nil
        networkIsReachable = false
        networkIsProbing = false

        if isRunning {
            restartNetworkTimer()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        frameCount = 0
        lastFPSUpdate = 0

        let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        sampleCPU()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleCPU()
        }
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer

        restartNetworkTimer()
    }

    func stop() {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        cpuTimer?.invalidate()
        cpuTimer = nil
        networkTimer?.invalidate()
        networkTimer = nil
        networkDataTask?.cancel()
        networkDataTask = nil
        networkIsProbing = false
        frameCount = 0
        lastFPSUpdate = 0
    }

    deinit {
        stop()
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        if lastFPSUpdate == 0 {
            lastFPSUpdate = link.timestamp
            return
        }

        frameCount += 1
        let elapsed = link.timestamp - lastFPSUpdate
        guard elapsed >= 0.5 else { return }

        fps = Int((Double(frameCount) / elapsed).rounded())
        frameCount = 0
        lastFPSUpdate = link.timestamp
    }

    private func sampleCPU() {
        cpuUsage = Self.currentProcessCPUUsage()
    }

    private func restartNetworkTimer() {
        networkTimer?.invalidate()
        networkTimer = nil
        networkDataTask?.cancel()
        networkDataTask = nil

        guard networkProbeBaseURL != nil else { return }
        sampleNetwork()

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sampleNetwork()
        }
        RunLoop.main.add(timer, forMode: .common)
        networkTimer = timer
    }

    private func sampleNetwork() {
        guard networkDataTask == nil,
              let baseURL = networkProbeBaseURL,
              let probeURL = Self.probeURL(from: baseURL)
        else { return }

        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-32767", forHTTPHeaderField: "Range")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let startedAt = ProcessInfo.processInfo.systemUptime
        networkIsProbing = true
        networkDataTask = networkSession.dataTask(with: request) { [weak self] data, response, error in
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - startedAt)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let bytes = data?.count ?? 0
            let succeeded = error == nil && statusCode != nil

            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isRunning, self.networkProbeBaseURL == baseURL else { return }
                self.networkDataTask = nil
                self.networkIsProbing = false

                if succeeded {
                    self.latencyMS = Int((elapsed * 1_000).rounded())
                    self.networkBytesPerSecond = bytes > 0 ? Double(bytes) / elapsed : nil
                    self.networkIsReachable = true
                } else {
                    self.latencyMS = nil
                    self.networkBytesPerSecond = nil
                    self.networkIsReachable = false
                }
            }
        }
        networkDataTask?.resume()
    }

    private static func normalizedNetworkProbeBaseURL(from value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              var components = URLComponents(string: value)
        else { return nil }
        if components.scheme == nil {
            components.scheme = "https"
        }
        guard components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func probeURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/favicon.ico"
        components.queryItems = [
            URLQueryItem(name: "iexa_perf", value: "\(Int(Date().timeIntervalSince1970))")
        ]
        return components.url
    }

    private static func currentProcessCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var totalUsage: Double = 0
        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info_data_t()
            var threadInfoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
            )
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { reboundPointer in
                    thread_info(
                        threadList[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        reboundPointer,
                        &threadInfoCount
                    )
                }
            }
            guard infoResult == KERN_SUCCESS else { continue }

            guard (threadInfo.flags & TH_FLAGS_IDLE) == 0 else { continue }

            totalUsage += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }

        return min(max(totalUsage, 0), 999)
    }
}

// MARK: - Model Selector Label (Extracted to avoid re-computing viewModel in MainChatView body)

/// A lightweight view that reads the active chat's model info
/// only when it actually needs to render. This avoids the parent
/// `MainChatView` body from accessing `ActiveChatStore.viewModel(for:)`
/// on every evaluation.
private struct MainModelSelectorLabel: View {
let conversationId: String?
    let activeChatStore: ActiveChatStore
    let theme: AppTheme

    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var isShowingModelSelectorSheet = false
    @State private var editingModelDetail: ModelDetail? = nil

    private var vm: ChatViewModel {
        activeChatStore.viewModel(for: conversationId)
    }

    var body: some View {
        Group {
            if vm.availableModels.isEmpty {
                Text("新对话")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            } else {
                Button {
                    Haptics.play(.light)
                    vm.refreshModelsInBackground()
                    isShowingModelSelectorSheet = true
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if let model = vm.selectedModel {
                            ModelAvatar(
                                size: 25,
                                imageURL: vm.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: vm.serverAuthToken
                            )
                            .fixedSize()
                        }
                        Text(vm.selectedModel?.shortName ?? "选择模型")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .iexaToolbarGlass(cornerRadius: 22, compact: true)
                    .clipShape(Capsule(style: .continuous))
                    .frame(maxWidth: 220)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingModelSelectorSheet) {
                    ModelSelectorSheet(
                        models: vm.availableModels,
                        selectedModelId: vm.selectedModelId,
                        serverBaseURL: vm.serverBaseURL,
                        authToken: vm.serverAuthToken,
                        isAdmin: dependencies.authViewModel.currentUser?.role == .admin,
                        pinnedModelIds: vm.pinnedModelIds,
                        onEdit: dependencies.authViewModel.currentUser?.role == .admin ? { model in
                            isShowingModelSelectorSheet = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await openModelEditor(for: model)
                            }
                        } : nil,
                        onTogglePin: { modelId in
                            vm.togglePinModel(modelId)
                        },
                        onSelect: { model in
                            vm.selectModel(model.id)
                        }
                    )
                    .themed()
                    .presentationBackgroundInteraction(.disabled)
                    .onDisappear {
                        Task { await ImageCacheService.shared.clearMemory() }
                    }
                }
            }
        }
        .sheet(item: $editingModelDetail) { detail in
            NavigationStack {
                ModelEditorView(existingModel: detail) { _ in
                    Task { vm.refreshModelsInBackground() }
                    editingModelDetail = nil
                }
            }
            .themed()
        }
    }

    private func openModelEditor(for model: AIModel) async {
        guard let apiClient = dependencies.apiClient else { return }
        do {
            let detail = try await apiClient.getWorkspaceModelDetail(id: model.id)
            editingModelDetail = detail
        } catch {
            // Base models (not yet customized as workspace models) return 404.
            // Construct a default ModelDetail so the editor opens in "create" mode.
            editingModelDetail = ModelDetail(
                id: model.id,
                name: model.name,
                description: model.description,
                profileImageURL: model.profileImageURL
            )
        }
    }
}
