// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UniformTypeIdentifiers

struct RecordDetailVisibilityKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct RecordListScreen: View {
    @Environment(\.navigationDockClearance) private var dockClearance
    let store: CallRecordStore
    let isCallActive: Bool
    var onRequestSummary: ((UUID) -> Void)? = nil
    var roleID: UUID? = nil
    var canRequestSummary: ((UUID) -> Bool)? = nil
    var isDockPage = false
    var roles: [CallRole] = []
    var onResumeCall: ((UUID) -> Void)? = nil
    var summaryConnections: [ConnectionProfile] = []
    var onRequestSummaryUsing: ((UUID, UUID) -> Void)? = nil
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var searchText = ""
    @State private var selectedRoleID: UUID?
    @ScaledMetric(relativeTo: .largeTitle) private var titleFontSize = 48.0
    @ScaledMetric(relativeTo: .headline) private var emptyTitleFontSize = 18.0
    @ScaledMetric(relativeTo: .footnote) private var emptyDescriptionFontSize = 14.0

    private var visibleRecords: [CallRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.finishedRecords.filter { record in
            guard roleID == nil || record.roleID == roleID else { return false }
            guard selectedRoleID == nil || record.roleID == selectedRoleID else { return false }
            guard !query.isEmpty else { return true }
            return record.roleName.localizedStandardContains(query)
                || record.summary.localizedStandardContains(query)
        }
    }

    private var filterContacts: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        return store.finishedRecords.compactMap { record in
            guard seen.insert(record.roleID).inserted else { return nil }
            return (record.roleID, roles.first(where: { $0.id == record.roleID })?.displayName ?? record.roleName)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selectedContactName: String? {
        filterContacts.first(where: { $0.id == selectedRoleID })?.name
    }

    var body: some View {
        Group {
            if isDockPage {
                content
                    .safeAreaBar(edge: .top, spacing: 0) { header }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .background(Color(.systemBackground))
                    .toolbar(.hidden, for: .navigationBar)
            } else {
                content
                    .navigationTitle(roleID == nil ? "Recents" : String(localized: "摘要管理"))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("导入文件夹", systemImage: "square.and.arrow.down") { isImporting = true }
                                .disabled(isCallActive)
                        }
                    }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let result = try store.importRecord(from: url)
                importMessage = result.imported ? String(localized: "已导入通话，按原通话时间排列。") : String(localized: "这通电话已在本机，已跳过重复导入并保留本机内容。")
            } catch { importMessage = String(localized: "导入失败：\(error.localizedDescription)") }
        }
        .alert("通话备份", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: { Text(importMessage ?? "") }
        .onChange(of: store.records.map(\.roleID)) { _, ids in
            if let selectedRoleID, !ids.contains(selectedRoleID) { self.selectedRoleID = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let issue = store.storageIssue {
                Text(issue)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            if isDockPage {
                recordList
                    .contentMargins(.bottom, dockClearance, for: .scrollContent)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
            } else {
                recordList
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedRoleID == nil ? String(localized: "暂无通话记录") : String(localized: "没有找到匹配的通话"))
                    .font(.system(size: emptyTitleFontSize, weight: .semibold))
            } icon: {
                Image(systemName: "phone")
            }
        } description: {
            Text("通话文字保存在本机，录音可在设置中开启。")
                .font(.system(size: emptyDescriptionFontSize))
        }
    }

    private var recordList: some View {
        List(visibleRecords) { record in
            VStack(spacing: 0) {
                NavigationLink {
                    RecordDetailScreen(recordID: record.id, store: store, isCallActive: isCallActive, onRequestSummary: onRequestSummary, canRequestSummary: canRequestSummary,
                                       avatarData: roles.first(where: { $0.id == record.roleID })?.displayAvatarData,
                                       onResumeCall: roles.contains(where: { $0.id == record.roleID }) ? onResumeCall : nil,
                                       summaryConnections: summaryConnections, onRequestSummaryUsing: onRequestSummaryUsing)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.roleName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    Text(record.startedAt, format: .dateTime.year().month().day().hour().minute())
                                    if record.isFinished, record.endedAbnormally != true {
                                        Text("·")
                                        callDuration(record)
                                    }
                                    interruptionLabel(record)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(record.startedAt, format: .dateTime.year().month().day().hour().minute())
                                        interruptionLabel(record)
                                    }
                                    if record.isFinished, record.endedAbnormally != true { callDuration(record) }
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            if roleID != nil, !record.summary.isEmpty {
                                Text(record.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 18)
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
        .overlay {
            if visibleRecords.isEmpty {
                emptyState
                    // Scroll content margins do not reserve space for this overlay.
                    .padding(.bottom, isDockPage ? dockClearance : 0)
            }
        }
    }

    @ViewBuilder private func interruptionLabel(_ record: CallRecord) -> some View {
        if record.endedAbnormally == true {
            Text("·")
            Text("异常中断").fontWeight(.medium)
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
            HStack(alignment: .center) {
                Text("Recents")
                    .font(.system(size: titleFontSize, weight: .bold))
                    .tracking(-2.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Picker("按联系人筛选", selection: $selectedRoleID) {
                        Text(String(localized: "全部联系人")).tag(nil as UUID?)
                        ForEach(filterContacts, id: \.id) { contact in
                            Text(contact.name).tag(Optional(contact.id))
                        }
                    }
                } label: {
                    Image(systemName: selectedRoleID == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color.primary, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("筛选通话")
                .accessibilityValue(selectedContactName ?? String(localized: "全部联系人"))
            }
            .padding(.top, 24)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                TextField("搜索通话", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("搜索通话")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
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
            Rectangle().fill(Color.primary).frame(height: 1)
                .accessibilityHidden(true)
            HStack {
                Text(selectedContactName.map { String(localized: "筛选 · \($0)") } ?? "CALL HISTORY").lineLimit(1)
                Spacer()
                Text(String(format: "%02d", visibleRecords.count))
            }
            .font(.system(size: 9, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.secondary)
            .padding(.top, 22)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }
}
