// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import Contacts
import ContactsUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

extension RoleEditor {
    var identityCard: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 12) {
                if role.usesSystemContactDetails {
                    avatar.accessibilityLabel("系统联系人头像")
                } else {
                    Button { isShowingPhotoPicker = true } label: { avatar }
                        .buttonStyle(.plain)
                        .disabled(isLinking)
                        .accessibilityLabel(role.avatarData == nil ? String(localized: "选择联系人图片") : String(localized: "更改联系人图片"))
                        .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedPhoto, matching: .images)
                }
                Text(role.usesSystemContactDetails ? String(localized: "系统头像") : String(localized: "更换头像"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("姓名")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("怎么称呼 TA", text: Binding(get: {
                    role.usesSystemContactDetails ? role.displayName : nameDraft
                }, set: {
                    nameDraft = $0
                    manualNameEdited = true
                }))
                .font(.title2.weight(.semibold))
                .textContentType(.name)
                .disabled(role.usesSystemContactDetails || isLinking)
                .accessibilityLabel("姓名")
                Rectangle().fill(Color.primary.opacity(0.3)).frame(height: 0.75)
                if role.usesSystemContactDetails {
                    Text("姓名与头像跟随系统联系人")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isLoadingPhoto { ProgressView("正在处理头像…") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    private var avatar: some View {
        ZStack {
            Rectangle()
                .stroke(Color.primary.opacity(0.55), lineWidth: 0.75)
                .rotationEffect(.degrees(8))
            Group {
                if let data = role.displayAvatarData, let image = UIImage(data: data) {
                    Image(uiImage: image).renderingMode(.original).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color(.secondarySystemBackground))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 46))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 96, height: 96)
            .clipped()
        }
        .frame(width: 96, height: 96)
    }

    var bindingCard: some View {
        card {
            Toggle("关联系统联系人", isOn: Binding(get: {
                role.linkedContact != nil || isLinking
            }, set: { enabled in
                if enabled { chooseSystemContact() }
                else {
                    invalidateSelection()
                    role.unlinkContact()
                    contactLinkIssue = nil
                    refreshUneditedNameDrafts()
                }
            }))
            if role.linkedContact != nil {
                Divider()
                Toggle("关联头像和姓名", isOn: Binding(get: { role.usesSystemContactDetails }, set: { enabled in
                    selectedPhoto = nil
                    isLoadingPhoto = false
                    if enabled {
                        role.syncSystemContactDetails = true
                        Task { await refreshDraftContact() }
                    } else {
                        contactLinkIssue = nil
                        role.stopSyncingContactDetails()
                        refreshUneditedNameDrafts()
                    }
                }))
                .disabled(isLinking)
                Menu(String(localized: "更换联系人")) {
                    Button("选择联系人", action: chooseSystemContact)
                    if CNContactStore.authorizationStatus(for: .contacts) == .limited {
                        Button("管理可访问的联系人") { isShowingAccessPicker = true }
                    }
                }
                    .font(.footnote)
                    .disabled(isLinking)
            }
            if isLinking { ProgressView("正在读取联系人…") }
            if let issue = displayedContactIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                contactRepairActions
            }
        }
    }

    private var displayedContactIssue: String? {
        if let contactLinkIssue { return contactLinkIssue }
        guard role.linkedContact != nil,
              store.roles.first(where: { $0.id == role.id })?.linkedContact?.identifier == role.linkedContact?.identifier else { return nil }
        return store.contactSyncIssues[role.id]
    }

    @ViewBuilder
    private var contactRepairActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if contactAccessNeedsSettings {
                Button("打开系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            } else {
                HStack(spacing: 20) {
                    Button("重新读取") {
                        Task { await refreshDraftContact() }
                    }
                    Button("重新选择", action: chooseSystemContact)
                }
                if CNContactStore.authorizationStatus(for: .contacts) == .limited {
                    Button("管理可访问的联系人") { isShowingAccessPicker = true }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .disabled(isLinking)
    }

    private var contactAccessNeedsSettings: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private func refreshUneditedNameDrafts() {
        if !manualNameEdited {
            nameDraft = role.name
        }
    }

    var hasDisplayName: Bool {
        if role.usesSystemContactDetails {
            return !role.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseSystemContact() {
        guard !isLinking else { return }
        selectedPhoto = nil
        isLoadingPhoto = false
        selectionRequestID = UUID()
        let requestID = selectionRequestID
        isLinking = true
        Task {
            do {
                let allowed = try await store.contactReader.requestAccess()
                guard editorIsActive, selectionRequestID == requestID else { return }
                guard allowed else {
                    throw TincallError(message: String(localized: "未获得通讯录权限。你可以在系统设置中开启；手动资料已保留。"))
                }
                isShowingContactPicker = true
            } catch {
                guard editorIsActive, selectionRequestID == requestID else { return }
                contactLinkIssue = error.localizedDescription
                isLinking = false
            }
        }
    }

    func selectSystemContact(_ snapshot: LinkedContact) {
        guard editorIsActive, isLinking else { return }
        role.linkedContact = snapshot
        contactLinkIssue = nil
        isShowingContactPicker = false
        isLinking = false
    }

    func refreshDraftContact() async {
        guard let identifier = role.linkedContact?.identifier else { return }
        let requestID = selectionRequestID
        do {
            let savedRole = store.roles.first { $0.id == role.id && $0.linkedContact?.identifier == identifier }
            let numbers = savedRole?.systemCallPhoneNumber.map { [role.id: $0] } ?? [:]
            let snapshot = try await store.contactReader.read(identifier: identifier, callNumbers: numbers)
            guard editorIsActive, requestID == selectionRequestID, role.linkedContact?.identifier == identifier else { return }
            role.linkedContact = snapshot
            contactLinkIssue = nil
            await store.refreshLinkedContacts()
        } catch {
            guard editorIsActive, requestID == selectionRequestID, role.linkedContact?.identifier == identifier else { return }
            contactLinkIssue = String(localized: "联系人未更新，已保留上次资料。\n\(error.localizedDescription)")
        }
    }

    func invalidateSelection() {
        selectionRequestID = UUID()
        isShowingContactPicker = false
        isShowingAccessPicker = false
        isLinking = false
    }
}
