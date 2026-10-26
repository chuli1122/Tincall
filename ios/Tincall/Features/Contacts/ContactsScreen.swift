// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct ContactsScreen: View {
    @Environment(\.navigationDockClearance) private var dockClearance
    let store: LocalConfigurationStore
    let isCallActive: Bool
    let onSelectRole: (UUID) -> Void
    var records: CallRecordStore? = nil
    var onRequestSummary: ((UUID) -> Void)? = nil
    var dismissEditorRequest: UUID? = nil

    @State private var editingRole: CallRole?
    @State private var editorInitialDraft: CallRole?
    @State private var latestEditorDraft: CallRole?
    @State private var interruptedDrafts: [UUID: CallRole] = [:]
    @State private var interruptedNewRole: CallRole?
    @State private var searchText = ""
    @ScaledMetric(relativeTo: .largeTitle) private var titleFontSize = 48.0
    @ScaledMetric(relativeTo: .body) private var avatarSize = 40.0

    private var visibleRoles: [CallRole] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.roles : store.roles.filter { $0.displayName.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            if let issue = store.contactSyncIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if visibleRoles.isEmpty {
                Text(store.roles.isEmpty ? String(localized: "轻点右上角的 + 添加联系人") : String(localized: "没有找到这个名字"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(visibleRoles.enumerated()), id: \.element.id) { index, role in
                VStack(spacing: 0) {
                    contactRow(role, index: index)
                        .padding(.vertical, 20)
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(height: 0.75)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .contentMargins(.bottom, dockClearance, for: .scrollContent)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(.systemBackground))
        .sheet(item: $editingRole) { role in
            NavigationStack {
                RoleEditor(role: role, store: store, records: records, isCallActive: isCallActive,
                           onRequestSummary: onRequestSummary, initialDraft: editorInitialDraft,
                           onDraftChange: { latestEditorDraft = $0 })
            }
            .environment(\.navigationDockClearance, 0)
        }
        .onChange(of: dismissEditorRequest) {
            guard let role = editingRole else { return }
            interruptedDrafts[role.id] = latestEditorDraft ?? role
            if !store.roles.contains(where: { $0.id == role.id }) { interruptedNewRole = role }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { editingRole = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TINCALL")
                Spacer()
                Text("PERSONAL DIRECTORY")
            }
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Text("Contacts")
                    .font(.system(size: titleFontSize, weight: .bold))
                    .tracking(-2.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: addContact) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color.primary, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加联系人")
            }
            .padding(.top, 24)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                TextField("搜索联系人", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("搜索联系人")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .frame(minHeight: 44)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Rectangle()
                .fill(Color.primary)
                .frame(height: 1)
                .accessibilityHidden(true)

            HStack {
                Text("YOUR PEOPLE")
                Spacer()
                Text(String(format: "%02d", visibleRoles.count))
            }
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)
            .padding(.top, 22)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private func contactRow(_ role: CallRole, index: Int) -> some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .leading)
                .accessibilityHidden(true)
            Button {
                editContact(role)
            } label: {
                HStack(spacing: 16) {
                    avatar(for: role)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(role.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let lastCall = records?.records.first(where: { $0.roleID == role.id }) {
                            Text("上次通话：\(lastCall.startedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("还没有通话")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑联系人 \(role.displayName)")

            Button {
                guard !isCallActive else { return }
                onSelectRole(role.id)
            } label: {
                    Image(systemName: "phone")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .overlay { Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 0.75) }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.accentColor)
            .disabled(isCallActive)
            .accessibilityLabel("选择 \(role.displayName) 通话")
            .accessibilityHint(isCallActive ? String(localized: "请先结束当前通话") : String(localized: "打开通话页"))
        }
    }

    private func avatar(for role: CallRole) -> some View {
        CallIdentityPortrait(name: role.displayName, data: role.displayAvatarData, size: avatarSize, coversFrame: false)
    }

    private func addContact() {
        let role = interruptedNewRole ?? CallRole(name: "")
        interruptedNewRole = nil
        editContact(role)
    }

    private func editContact(_ role: CallRole) {
        editorInitialDraft = interruptedDrafts.removeValue(forKey: role.id)
        latestEditorDraft = editorInitialDraft ?? role
        editingRole = role
    }
}
