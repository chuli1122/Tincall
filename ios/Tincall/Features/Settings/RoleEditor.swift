// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import AVFoundation
import Contacts
import ContactsUI
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

struct RoleEditor: View {
    @State var role: CallRole
    let store: LocalConfigurationStore
    let records: CallRecordStore?
    let isCallActive: Bool
    let onRequestSummary: ((UUID) -> Void)?
    let onDraftChange: ((CallRole) -> Void)?
    @State var nameDraft: String
    @State var savedRole: CallRole
    @State private var showsUnsavedChanges = false
    @State var manualNameEdited = false
    @State var errorMessage: String?
    @State var isShowingContactPicker = false
    @State var isShowingAccessPicker = false
    @State var isLinking = false
    @State var selectionRequestID = UUID()
    @State var selectedPhoto: PhotosPickerItem?
    @State var isShowingPhotoPicker = false
    @State var isLoadingPhoto = false
    @State var selectedBackground: PhotosPickerItem?
    @State var isShowingBackgroundPicker = false
    @State var isLoadingBackground = false
    @State private(set) var editorIsActive = true
    @State var contactLinkIssue: String?
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var editorTitleSize = 44.0
    @State var isShowingPromptEditor = false
    @State var isImportingPrompt = false
    @State private var isConfirmingDeletion = false
    @State var copiedMCPAddress = false
    @State var copiedMCPAuthorization = false
    @State var copiedWakeBridgeConfiguration = false
    @State var mcpAddressCopyTrigger: Date?
    @State var mcpAuthorizationCopyTrigger: Date?
    @State var wakeBridgeCopyTrigger: Date?
    @State var isCopyingWakeBridgeConfiguration = false
    @State private(set) var mcpSetup = RoleMCPSetup()
    @State var mcpUsesSSE = false
    @State var isSavingRole = false
    @State private var saveRequestID: UUID?
    @State private var saveFeedbackTrigger = 0
    @State private var showsSavedFeedback = false
    @State var manualMCPContactID: String?
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    init(role: CallRole, store: LocalConfigurationStore, records: CallRecordStore? = nil,
         isCallActive: Bool = false, onRequestSummary: ((UUID) -> Void)? = nil,
         initialDraft: CallRole? = nil, onDraftChange: ((CallRole) -> Void)? = nil) {
        let draft = initialDraft ?? role
        _role = State(initialValue: draft)
        self.store = store
        self.records = records
        self.isCallActive = isCallActive
        self.onRequestSummary = onRequestSummary
        self.onDraftChange = onDraftChange
        _nameDraft = State(initialValue: draft.name)
        _savedRole = State(initialValue: role)
    }

    var body: some View {
        let confirmation = confirmationPresentation(editorContent)
        let pickers = pickerPresentation(confirmation)
        let contacts = contactAccessPresentation(pickers)
        let lifecycle = lifecyclePresentation(contacts)
        let photoSelection = photoSelectionTask(lifecycle)
        return backgroundSelectionTask(photoSelection)
    }

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identityCard
                sectionHeading("01", "CONTACT LINK", title: String(localized: "联系人关联"))
                bindingCard
                sectionHeading("02", "CALL PREFERENCES", title: String(localized: "通话偏好"))
                voiceCard
                backgroundAndSummaryCard
                timeAwarenessCard
                sectionHeading("03", "CONNECTION MODE", title: String(localized: "连接模式"))
                modeCard
                if let errorMessage {
                    card {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if store.roles.contains(where: { $0.id == role.id }) {
                    Button(role: .destructive) { isConfirmingDeletion = true } label: {
                        HStack {
                            Text("删除联系人")
                            Spacer()
                            Image(systemName: "minus.circle")
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .padding(.top, 48)
                    .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        #if DEBUG
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-TincallOpenContactEditor") ? .bottom : nil)
        #endif
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .font(.subheadline)
        .tint(.accentColor)
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .disabled(isSavingRole)
        .modifier(CopySuccessFeedback())
        .modifier(DeploymentHelpOverlay())
        .overlay {
            if showsSavedFeedback {
                Label("已保存", systemImage: "checkmark")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsSavedFeedback)
        .task(id: saveFeedbackTrigger) {
            guard saveFeedbackTrigger > 0 else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            showsSavedFeedback = false
        }
        .background {
            ContactDismissGuard(isBlocked: isSavingRole, hasUnsavedChanges: hasUnsavedChanges, onAttempt: requestDismiss)
        }
    }

    private func confirmationPresentation<Content: View>(_ content: Content) -> some View {
        content
        .alert("要保存更改吗？", isPresented: $showsUnsavedChanges) {
            Button("保存", action: save).disabled(cannotSave)
            Button("放弃更改", role: .destructive, action: close)
            Button("取消", role: .cancel) { }
        } message: { Text("此页面有尚未保存的更改。") }
        .alert("确认删除联系人？", isPresented: $isConfirmingDeletion) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive, action: deleteContact)
        } message: {
            Text("从 Tincall 移除“\(store.roles.first(where: { $0.id == role.id })?.displayName ?? role.displayName)”。系统通讯录和已有通话记录会保留。")
        }
    }

    private func pickerPresentation<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $isShowingContactPicker, onDismiss: invalidateSelection) {
            SystemContactPicker(reader: store.contactReader, onSelect: selectSystemContact)
        }
        .sheet(isPresented: $isShowingPromptEditor) {
            NavigationStack {
                promptInput
                    .padding(16)
                    .background(Color(.systemBackground))
                    .navigationTitle("对话设定")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isShowingPromptEditor = false }
                        }
                    }
                    .tint(.accentColor)
            }
            .presentationDetents([.large])
        }
        .fileImporter(isPresented: $isImportingPrompt,
                      allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            importPrompt(result)
        }
    }

    private func contactAccessPresentation<Content: View>(_ content: Content) -> some View {
        content
        .contactAccessPicker(isPresented: $isShowingAccessPicker) { @Sendable _ in
            // ContactsUI can invoke this completion on its XPC queue, not the main actor.
            Task { @MainActor in
                await store.refreshLinkedContacts()
                await refreshDraftContact()
            }
        }
        .onChange(of: store.roles.first(where: { $0.id == role.id })?.linkedContact) { _, snapshot in
            if let snapshot, role.linkedContact?.identifier == snapshot.identifier {
                role.linkedContact = snapshot
                if savedRole.linkedContact?.identifier == snapshot.identifier { savedRole.linkedContact = snapshot }
            }
        }
    }

    private func lifecyclePresentation<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: roleWithDraftName, initial: true) { _, draft in onDraftChange?(draft) }
        .task(id: saveRequestID) {
            guard saveRequestID != nil else { return }
            await saveMCPRole()
        }
        .task(id: wakeBridgeConfigurationID) {
            guard wakeBridgeConfigurationID != nil, canCopyWakeBridgeConfiguration,
                  let connection = store.connections.first(where: { $0.id == role.externalConnectionID }) else { return }
            // Read both integrations when opening MCP settings; switching only changes presentation.
            guard mcpSetup.savedWakeConfiguration(connection: connection, contactID: role.mcpContactID) == nil else { return }
            guard !isCopyingWakeBridgeConfiguration else { return }
            await mcpSetup.loadWakeConfiguration(connection: connection, contactID: role.mcpContactID, role: savedWakeBridgeRole)
        }
        .onAppear {
            editorIsActive = true
            loadSavedMCPConfiguration()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, role.usesSystemContactDetails, !isLinking {
                Task { await refreshDraftContact() }
            }
        }
        .onDisappear {
            editorIsActive = false
            mcpSetup.invalidate()
            selectedPhoto = nil
            selectedBackground = nil
            invalidateSelection()
        }
    }

    private func photoSelectionTask<Content: View>(_ content: Content) -> some View {
        content
        .task(id: selectedPhoto) {
            guard let photo = selectedPhoto else { isLoadingPhoto = false; return }
            isLoadingPhoto = true
            defer { if selectedPhoto == photo { isLoadingPhoto = false } }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw TincallError(message: String(localized: "无法读取所选图片，请重新选择。"))
                }
                guard !Task.isCancelled, editorIsActive, !isLinking, !role.usesSystemContactDetails,
                      selectedPhoto == photo else { return }
                let thumbnail = try makeSettingsImageThumbnail(data, maxPixelSize: 512)
                guard !Task.isCancelled, editorIsActive, !isLinking, !role.usesSystemContactDetails,
                      selectedPhoto == photo else { return }
                role.avatarData = thumbnail
                errorMessage = nil
            } catch {
                if !Task.isCancelled, editorIsActive, !isLinking, !role.usesSystemContactDetails, selectedPhoto == photo {
                    errorMessage = String(localized: "头像未更改：\(error.localizedDescription)")
                }
            }
        }
    }

    private func backgroundSelectionTask<Content: View>(_ content: Content) -> some View {
        content
        .task(id: selectedBackground) {
            guard let photo = selectedBackground else { isLoadingBackground = false; return }
            isLoadingBackground = true
            defer { if selectedBackground == photo { isLoadingBackground = false } }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw TincallError(message: String(localized: "无法读取所选图片，请重新选择。"))
                }
                guard !Task.isCancelled, editorIsActive, selectedBackground == photo else { return }
                let thumbnail = try makeSettingsImageThumbnail(data, maxPixelSize: 1536)
                guard !Task.isCancelled, editorIsActive, selectedBackground == photo else { return }
                role.callBackgroundData = thumbnail
                selectedBackground = nil
                isLoadingBackground = false
                errorMessage = nil
            } catch {
                if !Task.isCancelled, editorIsActive, selectedBackground == photo {
                    errorMessage = String(localized: "通话背景未更改：\(error.localizedDescription)")
                    selectedBackground = nil
                    isLoadingBackground = false
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("TINCALL")
                Spacer()
                Text(store.roles.contains(where: { $0.id == role.id }) ? "EDIT CONTACT" : "NEW CONTACT")
            }
            .font(.system(size: 9, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Contact")
                    .font(.system(size: editorTitleSize, weight: .bold))
                    .tracking(-2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(store.roles.contains(where: { $0.id == role.id }) ? String(localized: "编辑联系人") : String(localized: "新建联系人"))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: requestDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .overlay { Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 0.75) }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭")
                Button(action: save) {
                    ZStack {
                        if isSavingRole { ProgressView().tint(Color(.systemBackground)) }
                        else { Image(systemName: "checkmark") }
                    }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(canSaveChanges || isSavingRole ? Color(.systemBackground) : Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(canSaveChanges || isSavingRole ? Color.accentColor : Color.clear)
                        .overlay { Rectangle().stroke(canSaveChanges || isSavingRole ? Color.clear : Color.primary.opacity(0.25), lineWidth: 0.75) }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!canSaveChanges)
                .accessibilityLabel(isSavingRole ? String(localized: "正在保存") : String(localized: "保存"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    var cannotSave: Bool {
        !hasDisplayName || isLinking || isLoadingPhoto || isLoadingBackground || selectedBackground != nil || isSavingRole
    }

    private var canSaveChanges: Bool {
        !cannotSave && (hasUnsavedChanges || !store.roles.contains(where: { $0.id == role.id }))
    }

    private var timeAwarenessCard: some View {
        card {
            HStack(spacing: 6) {
                Text("时间感知")
                DeploymentHelpButton(title: "时间感知说明", detail: "开启后会把消息的发送时间告诉 TA，使用手机的时间和时区。", systemImage: "info.circle")
                Spacer(minLength: 0)
                Toggle("时间感知", isOn: Binding(
                    get: { role.timeAwarenessEnabled == true },
                    set: { role.timeAwarenessEnabled = $0 }))
                    .labelsHidden()
            }
        }
    }

    var roleWithDraftName: CallRole {
        var draft = role
        if manualNameEdited {
            let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == savedRole.name.trimmingCharacters(in: .whitespacesAndNewlines) {
                draft.name = savedRole.name
                draft.familyName = savedRole.familyName
                draft.givenName = savedRole.givenName
            } else {
                draft.updateManualName(familyName: "", givenName: name)
            }
        }
        return draft
    }

    private var hasUnsavedChanges: Bool {
        comparableRole(roleWithDraftName) != comparableRole(savedRole)
    }

    private func comparableRole(_ value: CallRole) -> CallRole {
        var value = value
        value.callMode = value.effectiveCallMode
        value.mcpWakeBridgeEnabled = value.mcpWakeBridgeEnabled == true
        value.timeAwarenessEnabled = value.timeAwarenessEnabled == true
        value.mcpWaitTimeoutSeconds = value.effectiveMCPWaitTimeoutSeconds
        value.contextCharacterBudget = value.effectiveContextCharacterBudget
        value.contextModuleOrder = value.effectiveContextModuleOrder
        value.historySummaryCount = min(5, max(0, value.historySummaryCount ?? 3))
        value.summaryPrompt = value.effectiveSummaryPrompt
        value.summaryMaxCharacters = value.effectiveSummaryMaxCharacters
        value.syncSystemContactDetails = value.syncSystemContactDetails ?? true
        return value
    }

    private func requestDismiss() {
        guard !isSavingRole else { return }
        if hasUnsavedChanges { showsUnsavedChanges = true }
        else { close() }
    }

    func close() {
        editorIsActive = false
        mcpSetup.invalidate()
        selectedPhoto = nil
        selectedBackground = nil
        invalidateSelection()
        dismiss()
    }

    private func sectionHeading(_ number: String, _ caption: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(number)
                Spacer()
                Text(caption)
            }
            .font(.system(size: 9, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)
            Text(title).font(.headline)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Color.primary).frame(height: 1)
        }
        .padding(.top, 30)
    }

    func card<Content: View>(padding: CGFloat = 16, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, padding)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 0.75)
            }
    }

    private func save() {
        guard !isSavingRole else { return }
        role = roleWithDraftName
        errorMessage = nil
        if role.effectiveCallMode == .mcp && (!canReuseMCPConfiguration || savedRole.effectiveCallMode != .mcp) {
            guard role.externalConnectionID != nil else {
                errorMessage = String(localized: "请先选择一套 Tincall 云端连接。")
                return
            }
            guard !isCallActive else {
                errorMessage = String(localized: "请结束当前通话后再配置 MCP。")
                return
            }
            isSavingRole = true
            saveRequestID = UUID()
            return
        }
        if savedRole.effectiveCallMode != role.effectiveCallMode, role.effectiveCallMode != .mcp,
           let connectionID = savedRole.externalConnectionID {
            do {
                if try CredentialStore().readMCPConfiguration(connectionID: connectionID, roleID: role.id) != nil {
                    guard !isCallActive else {
                        errorMessage = String(localized: "请结束当前通话后再切换联系人模式。")
                        return
                    }
                    isSavingRole = true
                    saveRequestID = UUID()
                    return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        do {
            try store.saveRole(role)
            Task { await store.refreshLinkedContacts() }
            didSaveRole(role)
        } catch { errorMessage = error.localizedDescription }
    }

    func didSaveRole(_ next: CallRole) {
        role = next
        savedRole = next
        nameDraft = next.name
        manualNameEdited = false
        errorMessage = nil
        showsSavedFeedback = true
        saveFeedbackTrigger += 1
    }

    private func deleteContact() {
        do {
            try store.deleteRole(role.id)
            dismiss()
        } catch {
            errorMessage = String(localized: "联系人未删除：\(error.localizedDescription)")
        }
    }
}
