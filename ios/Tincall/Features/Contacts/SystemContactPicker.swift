// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import ContactsUI
import SwiftUI

struct SystemContactPicker: View {
    let reader: SystemContactReader
    let onSelect: (LinkedContact) -> Void
    @State private var contacts: [LinkedContact] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isSelecting = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var isShowingAccessPicker = false
    @State private var reloadID = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var visibleContacts: [LinkedContact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? contacts : contacts.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if CNContactStore.authorizationStatus(for: .contacts) == .limited {
                        Button("管理可访问的联系人") { isShowingAccessPicker = true }
                    }
                } footer: {
                    Text("仅显示已授权的联系人。保存关联后会添加 Tincall 专用通话号码，保留原有号码和邮箱；姓名与头像可选择同步。")
                }
                if isLoading {
                    ProgressView("正在读取联系人…")
                } else if visibleContacts.isEmpty {
                    Text(searchText.isEmpty ? String(localized: "暂无可关联的联系人") : String(localized: "没有找到这个名字"))
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("重新读取") { reloadID = UUID() }
                    }
                }
                ForEach(visibleContacts, id: \.identifier) { contact in
                    Button {
                        select(contact)
                    } label: {
                        HStack(spacing: 16) {
                            Group {
                                if let data = contact.avatarData, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(Color(.secondarySystemBackground))
                                        .overlay { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                                }
                            }
                            .frame(width: 40, height: 40)
                            .clipped()
                            Text(contact.name).foregroundStyle(.primary)
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(isSelecting)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "搜索已授权联系人")
            .navigationTitle("选择联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .tint(.accentColor)
        }
        .contactAccessPicker(isPresented: $isShowingAccessPicker) { @Sendable _ in
            // ContactsUI can call back from its XPC queue.
            Task { @MainActor in reloadID = UUID() }
        }
        .onChange(of: isShowingAccessPicker) { _, presented in
            if !presented { reloadID = UUID() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadID = UUID() }
        }
        .onDisappear { selectionTask?.cancel() }
        .task(id: reloadID) {
            isLoading = true
            defer { isLoading = false }
            do {
                let values = try await reader.availableContacts()
                guard !Task.isCancelled else { return }
                contacts = values
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                contacts = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func select(_ contact: LinkedContact) {
        isSelecting = true
        selectionTask = Task {
            defer { isSelecting = false }
            do {
                // Confirm ongoing access before committing the association.
                let snapshot = try await reader.read(identifier: contact.identifier)
                guard !Task.isCancelled else { return }
                onSelect(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
