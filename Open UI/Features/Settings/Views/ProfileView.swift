import SwiftUI
import PhotosUI

/// Modern, sleek account page inspired by Apple Settings > Apple ID.
struct ProfileView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    // MARK: - Editable Profile Fields
    @State private var editName = ""
    @State private var editBio = ""
    @State private var editGender = "Prefer not to say"
    @State private var editBirthDate: Date? = nil
    @State private var showBirthDatePicker = false
    @State private var editWebhookURL = ""

    // MARK: - Profile Image
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var profileImageData: Data?
    @State private var profileImageAction: ProfileImageAction = .keep
    @State private var showImageActionSheet = false
    @State private var showPhotoPicker = false

    // MARK: - Save State
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    // MARK: - Change Password
    @State private var showPasswordSection = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isChangingPassword = false
    @State private var passwordChangeSuccess = false
    @State private var passwordChangeError: String?

    // MARK: - Loading
    @State private var isLoadingSettings = false

    // MARK: - Original values (for smart save / change detection)
    @State private var originalName = ""
    @State private var originalBio = ""
    @State private var originalGender = "Prefer not to say"
    @State private var originalBirthDate: Date? = nil
    @State private var originalWebhookURL = ""

    // MARK: - Original avatar as base64 (captured at load to survive bio/name edits)
    /// When the user opens ProfileView we snapshot the current avatar as a base64 data URI.
    /// The `.keep` case in `saveProfile()` uses this so editing bio/name never sends an
    /// empty `profile_image_url` to the server, which would otherwise clear the avatar.
    @State private var originalAvatarBase64: String = ""

    private let genderOptions = ["Prefer not to say", "Male", "Female", "Custom"]

    private struct LocalProfileSnapshot: Codable {
        var name: String
        var bio: String
        var gender: String?
        var dateOfBirth: String?
        var webhookURL: String
        var profileImageURL: String?
    }

    enum ProfileImageAction {
        case keep, remove, initials, newImage(Data)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Hero card — avatar + identity
                heroCard
                    .padding(.top, Spacing.sm)

                // Profile fields
                profileSection

                // Notifications
                notificationsSection

                // Security
                securitySection

                // Save button
                saveButton
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.xl)
        }
        .background(theme.background)
        .navigationTitle("账号资料")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadCurrentValues() }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await handlePhotoSelection(newItem) }
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        HStack(spacing: Spacing.md + 4) {
            // Avatar with camera badge
            Button {
                showImageActionSheet = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    profileImage
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())

                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(theme.brandPrimary)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(theme.surfaceContainer, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            .confirmationDialog("头像", isPresented: $showImageActionSheet) {
                Button("从相册选择") {
                    showPhotoPicker = true
                }
                Button("使用首字母头像") {
                    profileImageAction = .initials
                    profileImageData = nil
                }
                Button("移除头像") {
                    profileImageAction = .remove
                    profileImageData = nil
                }
                Button("取消", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)

            // Name + email + role
            VStack(alignment: .leading, spacing: 4) {
                Text(user?.displayName ?? "用户")
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text(user?.email ?? "")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)

                if let role = user?.role.rawValue {
                    Text(roleDisplayName(role))
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md + 4)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("资料")

            VStack(spacing: 0) {
                // Name
                inlineEditRow(label: "名称", showDivider: true) {
                    TextField("你的名称", text: $editName)
                        .scaledFont(size: 16)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                }

                // Bio
                inlineEditRow(label: "简介", showDivider: true) {
                    TextField("介绍一下你的背景和兴趣", text: $editBio, axis: .vertical)
                        .scaledFont(size: 16)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                }

                // Gender
                inlineEditRow(label: "性别", showDivider: true) {
                    Picker("", selection: $editGender) {
                        ForEach(genderOptions, id: \.self) { option in
                            Text(genderDisplayName(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .tint(theme.textPrimary)
                }

                // Birth Date
                inlineEditRow(label: "生日", showDivider: false) {
                    if let date = editBirthDate {
                        HStack(spacing: Spacing.xs) {
                            Text(date, style: .date)
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)
                            Button {
                                withAnimation { editBirthDate = nil; showBirthDatePicker = false }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.25)) { showBirthDatePicker.toggle() }
                        }
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                editBirthDate = Date()
                                showBirthDatePicker = true
                            }
                        } label: {
                            Text("设置生日")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }

                if showBirthDatePicker, editBirthDate != nil {
                    DatePicker(
                        "生日",
                        selection: Binding(
                            get: { editBirthDate ?? Date() },
                            set: { editBirthDate = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("通知")

            VStack(spacing: 0) {
                inlineEditRow(label: "Webhook 地址", showDivider: false) {
                    TextField("输入 URL", text: $editWebhookURL)
                        .scaledFont(size: 16)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("安全")

            VStack(spacing: 0) {
                // Expand/collapse row
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        showPasswordSection.toggle()
                        if !showPasswordSection {
                            currentPassword = ""
                            newPassword = ""
                            confirmPassword = ""
                            passwordChangeError = nil
                            passwordChangeSuccess = false
                        }
                    }
                } label: {
                    HStack {
                        Text("修改密码")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(showPasswordSection ? 90 : 0))
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 14)
                }

                if showPasswordSection {
                    Divider().padding(.leading, Spacing.md)

                    VStack(spacing: Spacing.md) {
                        SecureField("当前密码", text: $currentPassword)
                            .textContentType(.password)
                            .padding(Spacing.md)
                            .background(theme.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                        SecureField("新密码", text: $newPassword)
                            .textContentType(.newPassword)
                            .padding(Spacing.md)
                            .background(theme.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                        SecureField("确认新密码", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .padding(Spacing.md)
                            .background(theme.surfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

                        if let error = passwordChangeError {
                            Text(error)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.error)
                        }

                        if passwordChangeSuccess {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(theme.success)
                                Text("密码修改成功")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.success)
                            }
                        }

                        Button {
                            Task { await changePassword() }
                        } label: {
                            HStack {
                                if isChangingPassword {
                                    ProgressView().controlSize(.small)
                                }
                                Text("更新密码")
                                    .scaledFont(size: 15, weight: .semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.sm)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.brandPrimary)
                        .disabled(
                            currentPassword.isEmpty ||
                            newPassword.count < 8 ||
                            newPassword != confirmPassword ||
                            isChangingPassword
                        )
                    }
                    .padding(Spacing.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        VStack(spacing: Spacing.sm) {
            if let error = saveError {
                Text(error)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.error)
                    .multilineTextAlignment(.center)
            }

            if saveSuccess {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                    Text("资料已保存")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.success)
                }
            }

            Button {
                Task { await saveProfile() }
            } label: {
                HStack(spacing: Spacing.sm) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text("保存")
                        .scaledFont(size: 17, weight: .semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(theme.brandPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            }
            .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            .opacity(editName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, Spacing.md)
    }

    private func genderDisplayName(_ value: String) -> String {
        switch value {
        case "Male": return "男"
        case "Female": return "女"
        case "Custom": return "自定义"
        case "Prefer not to say": return "不想透露"
        default: return value
        }
    }

    private func roleDisplayName(_ value: String) -> String {
        switch value.lowercased() {
        case "admin": return "管理员"
        case "user": return "用户"
        default: return value
        }
    }

    private func inlineEditRow<Content: View>(
        label: String,
        showDivider: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: Spacing.md)

                content()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 13)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    // MARK: - Profile Image

    @ViewBuilder
    private var profileImage: some View {
        if let data = profileImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if case .initials = profileImageAction {
            initialsAvatar
        } else if case .remove = profileImageAction {
            initialsAvatar
        } else {
            UserAvatar(
                size: 80,
                imageURL: profileImageURL,
                name: user?.displayName,
                authToken: dependencies.apiClient?.network.authToken,
                dataURIString: profileImageDataURI
            )
        }
    }

    private var initialsAvatar: some View {
        ZStack {
            Circle()
                .fill(theme.brandPrimary.opacity(0.2))
            Text(initialsText)
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
        }
    }

    private var initialsText: String {
        let name = editName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "?" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    // MARK: - Helpers

    private var user: User? { viewModel.currentUser }

    private var isLocalOnlyProfile: Bool {
        dependencies.apiClient?.providerType != .iexa
    }

    private var localProfileKey: String {
        let serverURL = dependencies.apiClient?.baseURL
            ?? dependencies.serverConfigStore.activeServer?.url
            ?? "default"
        return "iexa.local_profile.\(serverURL)"
    }

    private var profileImageDataURI: String? {
        guard let imageURL = user?.profileImageURL,
              imageURL.hasPrefix("data:") else { return nil }
        return imageURL
    }

    private var profileImageURL: URL? {
        if profileImageDataURI != nil { return nil }
        guard let userId = user?.id,
              let baseURL = dependencies.apiClient?.baseURL,
              !userId.isEmpty, !baseURL.isEmpty else { return nil }
        let v = viewModel.profileImageVersion
        return URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image?v=\(v)")
    }

    // MARK: - Data Loading

    private func loadCurrentValues() {
        Task {
            isLoadingSettings = true
            defer { isLoadingSettings = false }

            guard let api = dependencies.apiClient else {
                applyLocalProfileValues()
                return
            }

            if isLocalOnlyProfile {
                applyLocalProfileValues()
                return
            }

            // 1. Fetch fresh user data from server
            do {
                let freshUser = try await api.getCurrentUser()
                await MainActor.run { viewModel.currentUser = freshUser }
                viewModel.cacheCurrentUser()
            } catch {
                if loadLocalProfileSnapshot() != nil {
                    await MainActor.run { applyLocalProfileValues() }
                    return
                }
                // Fall back to cached user if server fetch fails.
            }

            guard let user = viewModel.currentUser else { return }

            await MainActor.run {
                // 2. Populate form fields from (fresh) user
                editName = user.displayName
                editBio = user.bio ?? ""

                if let gender = user.gender, !gender.isEmpty {
                    editGender = genderOptions.contains(gender) ? gender : "Custom"
                } else {
                    editGender = "Prefer not to say"
                }

                if let dob = user.dateOfBirth, !dob.isEmpty {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM/dd/yyyy"
                    editBirthDate = formatter.date(from: dob)
                } else {
                    editBirthDate = nil
                }

                // 3. Snapshot originals for change detection
                originalName = editName
                originalBio = editBio
                originalGender = editGender
                originalBirthDate = editBirthDate
            }

            // 4. Snapshot avatar as base64 so `.keep` in saveProfile() can preserve it
            // without relying on profileImageURL in the server response (which is empty
            // for server-hosted avatars and would clear the photo on bio/name edits).
            if let url = profileImageURL {
                if let cachedImage = await ImageCacheService.shared.loadImage(from: url, authToken: api.network.authToken),
                   let jpegData = cachedImage.jpegData(compressionQuality: 0.9) {
                    let b64 = "data:image/jpeg;base64," + jpegData.base64EncodedString()
                    await MainActor.run { originalAvatarBase64 = b64 }
                }
            }

            // 5. Load webhook URL from user settings
            do {
                let settings = try await api.getUserSettings()
                if let ui = settings["ui"] as? [String: Any],
                   let notifications = ui["notifications"] as? [String: Any],
                   let webhookUrl = notifications["webhook_url"] as? String {
                    await MainActor.run {
                        editWebhookURL = webhookUrl
                        originalWebhookURL = webhookUrl
                    }
                } else {
                    await MainActor.run {
                        editWebhookURL = ""
                        originalWebhookURL = ""
                    }
                }
            } catch {
                // Silently fail — webhook is optional
            }
        }
    }

    private func applyLocalProfileValues() {
        let snapshot = loadLocalProfileSnapshot()
        let cachedUser = viewModel.currentUser
        let name = snapshot?.name ?? cachedUser?.displayName ?? "API Key User"
        let bio = snapshot?.bio ?? cachedUser?.bio ?? ""
        let gender = snapshot?.gender ?? cachedUser?.gender
        let dob = snapshot?.dateOfBirth ?? cachedUser?.dateOfBirth
        let webhook = snapshot?.webhookURL ?? ""
        let avatar = snapshot?.profileImageURL ?? cachedUser?.profileImageURL

        editName = name
        editBio = bio
        if let gender, !gender.isEmpty {
            editGender = genderOptions.contains(gender) ? gender : "Custom"
        } else {
            editGender = "Prefer not to say"
        }
        if let dob, !dob.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd/yyyy"
            editBirthDate = formatter.date(from: dob)
        } else {
            editBirthDate = nil
        }
        editWebhookURL = webhook

        originalName = editName
        originalBio = editBio
        originalGender = editGender
        originalBirthDate = editBirthDate
        originalWebhookURL = webhook
        originalAvatarBase64 = avatar?.hasPrefix("data:") == true ? (avatar ?? "") : ""

        viewModel.currentUser = updatedLocalUser(
            name: name,
            bio: bio,
            gender: gender,
            dateOfBirth: dob,
            profileImageURL: avatar
        )
        viewModel.cacheCurrentUser()
    }

    private func loadLocalProfileSnapshot() -> LocalProfileSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: localProfileKey) else { return nil }
        return try? JSONDecoder().decode(LocalProfileSnapshot.self, from: data)
    }

    private func saveLocalProfileSnapshot(_ snapshot: LocalProfileSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: localProfileKey)
    }

    // MARK: - Photo Handling

    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                await MainActor.run {
                    profileImageData = data
                    profileImageAction = .newImage(data)
                }
            }
        } catch {
            // Silently fail
        }
    }

    // MARK: - Save Profile

    private func saveProfile() async {
        guard let api = dependencies.apiClient else { return }
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        saveError = nil
        saveSuccess = false

        // ── Capture the image URL BEFORE any mutations to avoid exclusive-access conflicts ──
        let avatarURL = profileImageURL
        let currentAction = profileImageAction

        do {
            // ── Step 1: Build the profile image payload ──
            let profileImageUrlString: String
            switch currentAction {
            case .keep:
                // Use the base64 snapshot captured when the view loaded.
                // This is the only reliable way to preserve a server-hosted avatar —
                // viewModel.currentUser?.profileImageURL is empty for server-hosted images,
                // so reading it would send "" and clear the avatar.
                profileImageUrlString = originalAvatarBase64
            case .remove, .initials:
                profileImageUrlString = ""
            case .newImage(let data):
                let base64 = data.base64EncodedString()
                let prefix: String
                if data.count >= 8 {
                    let header = [UInt8](data.prefix(8))
                    if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                        prefix = "data:image/png;base64,"
                    } else if header.starts(with: [0xFF, 0xD8]) {
                        prefix = "data:image/jpeg;base64,"
                    } else {
                        prefix = "data:image/png;base64,"
                    }
                } else {
                    prefix = "data:image/png;base64,"
                }
                profileImageUrlString = prefix + base64
            }

            // ── Step 2: Build remaining fields ──
            let genderValue: String?
            if editGender != originalGender {
                genderValue = editGender == "Prefer not to say" ? nil : editGender
            } else {
                genderValue = viewModel.currentUser?.gender
            }

            let dobValue: String?
            if editBirthDate != originalBirthDate {
                if let date = editBirthDate {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM/dd/yyyy"
                    dobValue = formatter.string(from: date)
                } else {
                    dobValue = nil
                }
            } else {
                dobValue = viewModel.currentUser?.dateOfBirth
            }

            if api.providerType != .iexa {
                await saveProfileLocally(
                    name: trimmedName,
                    bio: editBio,
                    gender: genderValue,
                    dateOfBirth: dobValue,
                    imageAction: currentAction,
                    avatarURL: avatarURL
                )
                return
            }

            // ── Step 3: Send update to server ──
            do {
                try await api.updateProfile(
                    name: trimmedName,
                    profileImageUrl: profileImageUrlString,
                    bio: editBio,
                    gender: genderValue,
                    dateOfBirth: dobValue
                )
            } catch {
                let apiError = APIError.from(error)
                if case .httpError(let code, _, _) = apiError, code == 404 || code == 405 {
                    await saveProfileLocally(
                        name: trimmedName,
                        bio: editBio,
                        gender: genderValue,
                        dateOfBirth: dobValue,
                        imageAction: currentAction,
                        avatarURL: avatarURL
                    )
                    return
                }
                throw error
            }

            // ── Step 4: Re-fetch the canonical user from server (single atomic assignment) ──
            let freshUser = try await api.getCurrentUser()
            viewModel.currentUser = freshUser
            viewModel.cacheCurrentUser()

            // Snapshot new originals for change detection
            originalName = trimmedName
            originalBio = editBio
            originalGender = editGender
            originalBirthDate = editBirthDate

            // ── Step 5: Update image cache ──
            if let url = avatarURL {
                switch currentAction {
                case .newImage(let imgData):
                    await ImageCacheService.shared.evict(for: url)
                    if let newImage = UIImage(data: imgData) {
                        await ImageCacheService.shared.store(newImage, for: url)
                    }
                    profileImageData = nil
                    profileImageAction = .keep
                case .remove, .initials:
                    await ImageCacheService.shared.evict(for: url)
                case .keep:
                    break
                }
            } else if case .newImage = currentAction {
                profileImageData = nil
                profileImageAction = .keep
            }

            // Bump version so all avatar views app-wide re-fetch the new image
            if case .keep = currentAction {
                // No image change — skip version bump
            } else {
                viewModel.profileImageVersion += 1
            }

            // ── Step 6: Update webhook if changed ──
            if editWebhookURL != originalWebhookURL {
                try await api.mergeUserUISettings([
                    "notifications": ["webhook_url": editWebhookURL]
                ])
                originalWebhookURL = editWebhookURL
            }

            // Done — show success
            isSaving = false
            saveSuccess = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveSuccess = false
        } catch {
            saveError = APIError.from(error).errorDescription ?? "更新资料失败。"
            isSaving = false
        }
    }

    private func saveProfileLocally(
        name: String,
        bio: String,
        gender: String?,
        dateOfBirth: String?,
        imageAction: ProfileImageAction,
        avatarURL: URL?
    ) async {
        let localImageURL: String? = {
            switch imageAction {
            case .keep:
                if !originalAvatarBase64.isEmpty { return originalAvatarBase64 }
                return viewModel.currentUser?.profileImageURL
            case .remove, .initials:
                return nil
            case .newImage(let data):
                return compressedAvatarDataURI(from: data)
            }
        }()

        let snapshot = LocalProfileSnapshot(
            name: name,
            bio: bio,
            gender: gender,
            dateOfBirth: dateOfBirth,
            webhookURL: editWebhookURL,
            profileImageURL: localImageURL
        )
        saveLocalProfileSnapshot(snapshot)

        viewModel.currentUser = updatedLocalUser(
            name: name,
            bio: bio,
            gender: gender,
            dateOfBirth: dateOfBirth,
            profileImageURL: localImageURL
        )
        viewModel.cacheCurrentUser()

        originalName = name
        originalBio = bio
        originalGender = editGender
        originalBirthDate = editBirthDate
        originalWebhookURL = editWebhookURL
        originalAvatarBase64 = localImageURL?.hasPrefix("data:") == true ? (localImageURL ?? "") : ""

        if let avatarURL {
            await ImageCacheService.shared.evict(for: avatarURL)
        }
        if case .keep = imageAction {
            // No avatar change.
        } else {
            profileImageData = nil
            profileImageAction = .keep
            viewModel.profileImageVersion += 1
        }

        isSaving = false
        saveSuccess = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        saveSuccess = false
    }

    private func updatedLocalUser(
        name: String,
        bio: String,
        gender: String?,
        dateOfBirth: String?,
        profileImageURL: String?
    ) -> User {
        let existing = viewModel.currentUser
        let username = {
            let existingUsername = existing?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return existingUsername.isEmpty ? name : existingUsername
        }()
        return User(
            id: existing?.id ?? "local-api-key-user",
            username: username,
            email: existing?.email ?? "",
            name: name,
            profileImageURL: profileImageURL,
            role: existing?.role ?? .user,
            isActive: existing?.isActive ?? true,
            bio: bio,
            gender: gender,
            dateOfBirth: dateOfBirth,
            permissions: existing?.permissions
        )
    }

    private func compressedAvatarDataURI(from data: Data) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 512
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = resized.jpegData(compressionQuality: 0.82) else { return nil }
        return "data:image/jpeg;base64," + jpegData.base64EncodedString()
    }

    // MARK: - Change Password

    private func changePassword() async {
        guard let api = dependencies.apiClient else { return }
        guard newPassword == confirmPassword else {
            passwordChangeError = "两次输入的密码不一致。"
            return
        }
        guard newPassword.count >= 8 else {
            passwordChangeError = "密码至少需要 8 个字符。"
            return
        }

        isChangingPassword = true
        passwordChangeError = nil
        passwordChangeSuccess = false

        do {
            try await api.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            passwordChangeSuccess = true
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
        } catch {
            let apiError = APIError.from(error)
            if case .httpError(let code, let msg, _) = apiError, code == 400 || code == 401 {
                passwordChangeError = msg ?? "当前密码不正确。"
            } else {
                passwordChangeError = apiError.errorDescription ?? "修改密码失败。"
            }
        }

        isChangingPassword = false
    }
}
