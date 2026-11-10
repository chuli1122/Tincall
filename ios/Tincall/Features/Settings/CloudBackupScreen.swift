// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CloudBackupScreen: View {
    let configuration: LocalConfigurationStore
    let records: CallRecordStore
    let sync: CloudSyncStore
    let isCallActive: Bool
    @State private var loadingError: String?
    @State private var confirmation: Confirmation?
    @State private var operation: Task<Void, Never>?
    @State private var searchText = ""
    @State private var activeRecordID: UUID?
    @State private var previewImage: CloudImagePreview?
    @State private var showsCloudCleanup = false
    @State private var loadedDetailID: UUID?

    private enum Confirmation: Identifiable {
        case destination, media, delete(UUID), deleteAll(ConnectionProfile, [CloudSyncRemote]), useLocal(UUID), restore(UUID, Bool), discard
        /// nil ids: every cloud copy of the selected service.
        case removeMedia([UUID]?, audio: Bool, images: Bool), reupload(UUID)
        var id: String {
            if case .deleteAll(let connection, _) = self { return "delete-all-\(connection.id)" }
            return String(describing: self)
        }
        var isDestructive: Bool {
            switch self { case .delete, .deleteAll, .discard, .removeMedia: true; default: false }
        }
        /// Clearing a whole service is confirmed in a standard alert, like the app's other deletions.
        var isCleanup: Bool {
            switch self { case .deleteAll, .removeMedia(nil, _, _): true; default: false }
        }
        var recordID: UUID? {
            switch self {
            case .delete(let id), .useLocal(let id), .restore(let id, _), .reupload(let id): id
            case .removeMedia(let ids?, _, _) where ids.count == 1: ids[0]
            default: nil
            }
        }
    }

    private var isSupabaseService: Bool {
        connection?.endpoint?.host?.lowercased().hasSuffix(".supabase.co") == true
    }

    private var connection: ConnectionProfile? {
        configuration.connections.first { $0.id == sync.selectedConnectionID && $0.provider == .genericConnector }
    }

    var body: some View {
        SettingsList { backupSections(sync) }
            .modifier(SettingsPageStyle(title: String(localized: "云端同步"), subtitle: String(localized: "在本机与自己的云端之间同步通话记录"), symbol: "icloud", index: "SYNC"))
        .task(id: isCallActive ? nil : connection?.id) {
            guard let connection, !isCallActive, !sync.isBusy, !sync.connected else { return }
            if await sync.refresh(connection: connection) { confirmation = .destination }
        }
        .alert("云端操作未完成", isPresented: Binding(get: { activeRecordID == nil && (sync.errorMessage != nil || loadingError != nil) }, set: { if !$0 { sync.clearError(); loadingError = nil } })) {
            Button("好", role: .cancel) { sync.clearError(); loadingError = nil }
        } message: { Text(sync.errorMessage ?? loadingError ?? "") }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil && confirmation?.recordID == nil && confirmation?.isCleanup != true }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            confirmationButtons
        } message: { Text(confirmationMessage) }
        .alert(confirmationTitle, isPresented: Binding(get: { confirmation?.isCleanup == true }, set: { if !$0 { confirmation = nil } })) {
            Button("取消", role: .cancel) { confirmation = nil }
            Button("清空", role: .destructive) { if let confirmation { perform(confirmation) } }
                .disabled(sync.isBusy || isCallActive)
        } message: { Text(confirmationMessage) }
    }

    @ViewBuilder private func backupSections(_ sync: CloudSyncStore) -> some View {
        if connection != nil, let usage = sync.usage {
            Section {
                SettingsUsageBar(segments: [
                    .init(title: String(localized: "录音"), bytes: usage.audio_bytes, detail: String(localized: "\(usage.audio_count) 段")),
                    .init(title: String(localized: "图片"), bytes: usage.image_bytes, detail: String(localized: "\(usage.image_count) 张")),
                ], capacity: isSupabaseService ? 1_000_000_000 : nil)
            } header: { SettingsSectionHeading(title: String(localized: "云端空间"), caption: "STORAGE") } footer: {
                // Only a Supabase project has a known plan limit; a self-hosted service uses its own disk.
                (Text("按 \(usage.records) 通云端备份中记录的文件大小统计。") + (isSupabaseService
                    ? Text("Supabase 免费版的文件存储上限为 1 GB，实际额度以 Supabase 控制台为准。")
                    : Text("部署在自己的电脑或服务器上时，可用空间取决于那台设备的磁盘。")))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !configuration.connections.contains(where: { $0.provider == .genericConnector }) {
            Section {
                Text("请到「设置 → Tincall 云端」部署或连接服务。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { SettingsSectionHeading(title: String(localized: "同步服务"), caption: "SERVICE") }
        }
        if configuration.connections.contains(where: { $0.provider == .genericConnector }) {
            Section {
                SettingsPickerRow(title: String(localized: "使用的云端"), value: connection?.name ?? String(localized: "未选择"), selection: Binding(get: { sync.selectedConnectionID }, set: { id in save { try sync.select(id) } })) {
                    Text("未选择").tag(nil as UUID?)
                    ForEach(configuration.connections.filter { $0.provider == .genericConnector }) { value in
                        Text(value.name).tag(Optional(value.id))
                    }
                }
                .disabled(sync.isBusy || isCallActive)
                if let connection {
                    DisclosureGroup("服务地址") {
                        Text(connection.endpoint?.absoluteString ?? String(localized: "尚未填写地址"))
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } header: { SettingsSectionHeading(title: String(localized: "同步服务"), caption: "SERVICE") }
        }
        if connection != nil {
            Section {
                Toggle("自动同步通话内容", isOn: Binding(get: { sync.automaticSyncEnabled }, set: { enabled in save { try sync.setAutomaticSyncEnabled(enabled) } }))
                if let connection {
                    Button("立即同步") {
                        run {
                            do { try sync.setTextSyncEnabled(true) }
                            catch { loadingError = error.localizedDescription; return }
                            await sync.synchronize(connection: connection)
                        }
                    }
                    .disabled(sync.isBusy || isCallActive)
                }
            } header: { SettingsSectionHeading(title: String(localized: "通话内容"), caption: "CALLS") } footer: {
                Text("同步文字、图片和摘要：本机更新上传到云端，云端更新下载到本机。开启后在打开 App、回到前台或通话保存后自动同步；通话期间暂停。联系人与设置保留在本机。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("同步已保存的录音", isOn: Binding(get: { sync.mediaEnabled }, set: { enabled in
                    if enabled { confirmation = .media } else { save { try sync.setMediaEnabled(false) } }
                }))
                .disabled(!sync.mediaEnabled && (!sync.connected || sync.isBusy))
                if !sync.connected && !sync.isBusy {
                    Text("请先在下方刷新云端记录，连接成功后可开启录音同步。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let connection {
                    Button("上传本机已有录音") { run { await sync.backupMedia(connection: connection) } }
                        .disabled(!sync.mediaEnabled || sync.isBusy || isCallActive)
                }
            } header: { SettingsSectionHeading(title: String(localized: "录音"), caption: "AUDIO") } footer: {
                Text("录音文件可能较大，会占用云端存储和上传、下载流量，因此默认不同步。允许后，自动同步会上传已保存的录音，并下载本机缺少的录音。此开关不会开启通话录音。")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(sync.status).font(.footnote)
                if sync.isBusy {
                    // The refresh row turns into the spinner while any cloud operation runs.
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    if let operation {
                        Button("停止本次操作") { operation.cancel() }
                    } else if sync.automaticSyncEnabled {
                        Button("停止自动同步") { save { try sync.setAutomaticSyncEnabled(false) } }
                    }
                } else if let connection {
                    Button("刷新云端记录") {
                        run { if await sync.refresh(connection: connection) { confirmation = .destination } }
                    }
                    .disabled(isCallActive)
                }
                if sync.hasPendingOperation, let connection {
                    Button("继续上次操作") { run { await sync.continuePending(connection: connection) } }
                        .disabled(sync.isBusy || isCallActive)
                    if sync.canDiscardPending {
                        Button("清理未提交的操作", role: .destructive) { confirmation = .discard }
                            .disabled(sync.isBusy || isCallActive)
                    }
                }
                if isCallActive { Text("通话结束后再同步或恢复记录。").foregroundStyle(.secondary) }
            } header: { SettingsSectionHeading(title: String(localized: "同步状态"), caption: "STATUS") } footer: {
                Text("刷新只读取云端列表。「立即同步」会上传和下载通话内容，即使自动同步已关闭也可使用。")
                    .font(.footnote).foregroundStyle(.secondary)
                if sync.hasPendingOperation {
                    Text("未完成的操作已保存在本机。继续时沿用原请求，提交结果未确认前不会删除已上传录音。")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if !sync.remoteRecords.isEmpty {
            Section {
                NavigationLink {
                    cloudRecords
                } label: {
                    SettingsActionLabel(title: String(localized: "云端记录"), symbol: "clock",
                                        detail: String(localized: "共 \(sync.remoteRecords.count) 通"))
                }
                if let connection {
                    Button { showsCloudCleanup = true } label: {
                        SettingsActionLabel(title: String(localized: "清理云端数据"), symbol: "trash", detail: String(localized: "录音、图片或整个备份"))
                    }
                    .buttonStyle(.plain)
                    .disabled(sync.isBusy || isCallActive || sync.hasPendingOperation || !sync.remoteRecords.contains(where: { !$0.deleted }))
                    // The menu explains the choices; each choice is then confirmed in an alert.
                    .confirmationDialog("清理云端数据", isPresented: $showsCloudCleanup, titleVisibility: .visible) {
                        if sync.supportsMediaRemoval {
                            if sync.usage?.audio_count != 0 {
                                Button("清空全部云端录音", role: .destructive) { confirmAfterMenu(.removeMedia(nil, audio: true, images: false)) }
                            }
                            if sync.usage?.image_count != 0 {
                                Button("清空全部云端图片", role: .destructive) { confirmAfterMenu(.removeMedia(nil, audio: false, images: true)) }
                            }
                        }
                        Button("清空当前云端备份", role: .destructive) {
                            run {
                                if let selection = await sync.backupsForDeletion(connection: connection), !selection.isEmpty {
                                    confirmation = .deleteAll(connection, selection)
                                }
                            }
                        }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("清空录音或图片：只删云端，文字和摘要保留，本机不受影响，之后同步不会再上传它们。清空当前云端备份：删除云端文字、摘要、图片和录音，本机记录保留。")
                    }
                }
            } header: { SettingsSectionHeading(title: String(localized: "记录管理"), caption: "RECORDS") }
        }
    }

    private var cloudRecords: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(visibleRemoteRecords) { remote in
                    NavigationLink {
                        cloudRecordDetails(id: remote.id)
                    } label: {
                        cloudRecordCard(remote)
                    }
                    .buttonStyle(.plain)
                }
                if visibleRemoteRecords.isEmpty {
                    Text("没有找到匹配的通话").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        // The search stays under the page header instead of scrolling away.
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SettingsTextField(placeholder: String(localized: "搜索联系人或日期"), text: $searchText, returnKey: .search, plain: true)
            }
            .font(.subheadline)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 10)
        }
        .modifier(SettingsPageStyle(title: String(localized: "云端记录"), subtitle: String(localized: "选择一通电话，查看并管理云端副本"), symbol: "clock", index: "CLOUD RECORDS"))
    }

    private func cloudRecordCard(_ remote: CloudSyncRemote) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(recordName(remote)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if let date = recordDate(remote) {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if remote.deleted {
                    Text("云端已删除").font(.caption).foregroundStyle(.secondary)
                } else if sync.conflicts.contains(remote.id) {
                    Text("需要处理冲突").font(.caption).foregroundStyle(.orange)
                } else if let facts = mediaFacts(remote), facts.audioCount + facts.imageCount > 0 {
                    Text(mediaLine(facts)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
        .contentShape(Rectangle())
    }

    private var visibleRemoteRecords: [CloudSyncRemote] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sync.remoteRecords.filter { remote in
            query.isEmpty || recordName(remote).localizedStandardContains(query) ||
                recordDate(remote)?.formatted(.dateTime.year().month().day().hour().minute()).localizedStandardContains(query) == true
        }.sorted { (recordDate($0) ?? .distantPast) > (recordDate($1) ?? .distantPast) }
    }

    private func recordName(_ remote: CloudSyncRemote) -> String {
        records.records.first { $0.id == remote.id }?.roleName ?? remote.record?.call.roleName
            ?? remote.summary?.role_name ?? String(localized: "云端通话")
    }

    private func recordDate(_ remote: CloudSyncRemote) -> Date? {
        records.records.first { $0.id == remote.id }?.startedAt ?? remote.record?.call.startedAt
            ?? remote.summary?.started_at ?? updatedDate(remote)
    }

    private func updatedDate(_ remote: CloudSyncRemote) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: remote.updated_at) ?? ISO8601DateFormatter().date(from: remote.updated_at)
    }

    private func cloudRecordDetails(id: UUID) -> some View {
        SettingsList {
            if let remote = sync.remoteRecords.first(where: { $0.id == id }) {
                let document = remote.record
                let local = records.records.first { $0.id == id }
                Section {
                    Text(recordName(remote)).font(.headline)
                    if let date = recordDate(remote) {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    if let duration = document?.call.recordedDuration {
                        LabeledContent("时长", value: Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond)))
                    }
                    if let connection { LabeledContent("所属云端", value: connection.name) }
                    if let date = updatedDate(remote) {
                        LabeledContent("云端更新", value: date.formatted(.dateTime.year().month().day().hour().minute()))
                    }
                    if remote.deleted { Text("云端已删除，本机副本保留").foregroundStyle(.secondary) }
                    if sync.conflicts.contains(id) { Text("版本冲突，尚未覆盖任一份内容").foregroundStyle(.orange) }
                } header: { SettingsSectionHeading(title: String(localized: "通话信息"), caption: "CALL") }
                if !remote.deleted {
                    if let document {
                        Section {
                            if case let summary = document.call.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("摘要").font(.caption).foregroundStyle(.secondary)
                                    Text(summary).font(.subheadline)
                                }
                            }
                            DisclosureGroup("对话 \(document.call.messages.count) 条") {
                                ForEach(document.call.messages) { message in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(message.role == .user ? String(localized: "我") : recordName(remote))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(message.recordedText.isEmpty ? String(localized: "（无文字）") : message.recordedText)
                                            .font(.subheadline)
                                    }
                                }
                            }
                            let images = document.imageReferences ?? []
                            if !images.isEmpty {
                                DisclosureGroup("图片 \(images.count) 张 · \(bytes(Int64(images.reduce(0) { $0 + $1.bytes })))") {
                                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                                        Button {
                                            openImage(image, recordID: id)
                                        } label: {
                                            LabeledContent("图片 \(index + 1)", value: bytes(Int64(image.bytes)))
                                        }
                                        .disabled(sync.isBusy)
                                    }
                                }
                            }
                            if !document.media.isEmpty {
                                DisclosureGroup("录音 \(document.media.count) 段 · \(bytes(Int64(document.media.reduce(0) { $0 + $1.bytes })))") {
                                    ForEach(Array(document.media.enumerated()), id: \.element.object_id) { index, media in
                                        LabeledContent("录音 \(index + 1)") {
                                            Text([media.asset.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) },
                                                  bytes(Int64(media.bytes))].compactMap { $0 }.joined(separator: " · "))
                                        }
                                    }
                                }
                            }
                        } header: { SettingsSectionHeading(title: String(localized: "云端内容"), caption: "CONTENTS") }
                    } else if sync.isBusy {
                        Section { ProgressView("正在读取云端内容…") }
                    }
                }
                Section {
                    if !remote.deleted {
                        Button("下载云端内容") { confirmation = .restore(id, false) }
                        if sync.mediaEnabled { Button("下载内容与已备份录音") { confirmation = .restore(id, true) } }
                    }
                    if local != nil {
                        Button(remote.deleted ? String(localized: "重新建立云端副本") : String(localized: "用本机内容更新云端")) { confirmation = .useLocal(id) }
                    }
                    if !remote.deleted, local != nil, sync.cloudClearedAudio.contains(id) || sync.cloudClearedImages.contains(id) {
                        Button("重新上传本机录音和图片") { confirmation = .reupload(id) }
                    }
                    if !remote.deleted, sync.supportsMediaRemoval, let document {
                        if !document.media.isEmpty {
                            Button("只删除云端录音", role: .destructive) { confirmation = .removeMedia([id], audio: true, images: false) }
                        }
                        if document.imageReferences?.isEmpty == false {
                            Button("只删除云端图片", role: .destructive) { confirmation = .removeMedia([id], audio: false, images: true) }
                        }
                    }
                    if !remote.deleted { Button("删除整通云端副本", role: .destructive) { confirmation = .delete(id) } }
                } header: { SettingsSectionHeading(title: String(localized: "管理副本"), caption: "ACTIONS") }
                .disabled(sync.isBusy || isCallActive)
                if sync.isBusy, remote.record != nil { ProgressView("正在处理…") }
            }
        }
        .modifier(SettingsPageStyle(title: String(localized: "云端通话"), subtitle: String(localized: "查看并管理这通电话的云端副本"), symbol: "icloud", index: "CLOUD RECORD"))
        .onAppear { activeRecordID = id }
        .onDisappear {
            if activeRecordID == id { activeRecordID = nil }
            if loadedDetailID == id { loadedDetailID = nil }
        }
        .task(id: id) { await loadDetailIfNeeded(id) }
        // A sync running when the page opened blocks the read; try again once it ends.
        .onChange(of: sync.isBusy) { _, busy in if !busy { Task { await loadDetailIfNeeded(id) } } }
        .sheet(item: $previewImage) { preview in
            NavigationStack {
                Group {
                    if let image = UIImage(data: preview.data) {
                        Image(uiImage: image).resizable().scaledToFit().padding()
                    } else {
                        ContentUnavailableView("无法显示这张图片", systemImage: "photo")
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { previewImage = nil } } }
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation?.recordID == id }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            confirmationButtons
        } message: { Text(confirmationMessage) }
        .alert("云端操作未完成", isPresented: Binding(get: { activeRecordID == id && (sync.errorMessage != nil || loadingError != nil) }, set: { if !$0 { sync.clearError(); loadingError = nil } })) {
            Button("好", role: .cancel) { sync.clearError(); loadingError = nil }
        } message: { Text(sync.errorMessage ?? loadingError ?? "") }
    }

    private func loadDetailIfNeeded(_ id: UUID) async {
        guard let connection, !isCallActive, !sync.isBusy, loadedDetailID != id,
              sync.remoteRecords.first(where: { $0.id == id })?.deleted == false else { return }
        loadedDetailID = id
        await sync.loadDetail(connection: connection, id: id)
    }

    /// A second dialog cannot appear while the menu is still dismissing.
    private func confirmAfterMenu(_ value: Confirmation) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            confirmation = value
        }
    }

    private func openImage(_ image: CloudSyncImageReference, recordID: UUID) {
        guard let connection else { return }
        run {
            do { previewImage = CloudImagePreview(data: try await sync.cloudImage(connection: connection, recordID: recordID, image: image)) }
            catch { loadingError = error.localizedDescription }
        }
    }

    private struct MediaFacts { let audioCount: Int; let audioBytes: Int64; let imageCount: Int; let imageBytes: Int64 }

    /// The loaded body is exact; otherwise the list summary from the service.
    private func mediaFacts(_ remote: CloudSyncRemote) -> MediaFacts? {
        if let document = remote.record {
            let images = document.imageReferences ?? []
            return MediaFacts(audioCount: document.media.count, audioBytes: Int64(document.media.reduce(0) { $0 + $1.bytes }),
                              imageCount: images.count, imageBytes: Int64(images.reduce(0) { $0 + $1.bytes }))
        }
        return remote.summary.map { MediaFacts(audioCount: $0.audio_count, audioBytes: $0.audio_bytes, imageCount: $0.image_count, imageBytes: $0.image_bytes) }
    }

    private func mediaLine(_ facts: MediaFacts) -> String {
        var parts: [String] = []
        if facts.audioCount > 0 { parts.append(String(localized: "录音 \(facts.audioCount)")) }
        if facts.imageCount > 0 { parts.append(String(localized: "图片 \(facts.imageCount)")) }
        parts.append(bytes(facts.audioBytes + facts.imageBytes))
        return parts.joined(separator: " · ")
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    private var confirmationTitle: String {
        switch confirmation {
        case .destination: return String(localized: "确认同步目标？")
        case .media: return String(localized: "允许录音上传与下载？")
        case .delete: return String(localized: "删除这通电话的云端副本？")
        case .deleteAll: return String(localized: "清空当前云端备份？")
        case .useLocal: return String(localized: "用本机文字更新云端？")
        case .restore: return String(localized: "恢复此云端版本？")
        case .discard: return String(localized: "清理未提交的云端操作？")
        case .removeMedia(let ids, let audio, _):
            if ids == nil { return audio ? String(localized: "清空全部云端录音？") : String(localized: "清空全部云端图片？") }
            return audio ? String(localized: "删除这通电话的云端录音？") : String(localized: "删除这通电话的云端图片？")
        case .reupload: return String(localized: "重新上传本机录音和图片？")
        case nil: return String(localized: "确认操作")
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .destination:
            return String(localized: "目的地：\(connection?.endpoint?.absoluteString ?? String(localized: "未配置"))。将读取此服务和当前令牌所属账户的记录；之后会按已开启的同步设置向该目标发送通话文字、图片、摘要及另行允许的录音。请确认这是你信任的服务和账户。")
        case .media:
            return String(localized: "目的地：\(connection?.endpoint?.absoluteString ?? String(localized: "未配置"))。录音包含声音和对话隐私，会保存到该项目的私有存储；项目管理者可访问。上传、存储及下载可能产生费用。开启自动同步后，会上传本机已保存的录音，并下载云端已有的录音，不会开启新的录音。")
        case .delete: return String(localized: "将删除这通电话的云端文字、图片、摘要和已备份录音，本机记录保留。之后自动同步或手动点击同步，都不会将这通记录重新上传；其他通话仍正常同步。")
        case .deleteAll(let connection, let selection):
            return String(localized: "将删除「\(connection.name)」中的 \(selection.count) 通云端备份，包括文字、图片、摘要和已备份录音。本机记录、MCP 通话数据和来电计划保留。已删除的记录不会随自动或手动同步重新上传，之后的新通话仍正常同步。")
        case .useLocal: return String(localized: "按当前云端版本提交本机文字与摘要。此操作可能替换另一台设备保存的文字，已有云端录音保留；若版本又有变化会再次停止。")
        case .restore(_, let media): return String(localized: "本机文字不同时先另存完整本机副本，再采用云端文字。\(media ? String(localized: "同时下载云端已备份录音，可能产生流量费用。") : String(localized: "不下载云端录音，本机已保存录音尽量保留。"))不会恢复旧通话的发送或取消任务。")
        case .discard: return String(localized: "清理本次未发布且未被云端记录引用的图片和录音对象，保留本机记录及已发布的云端内容。")
        case .removeMedia(let ids, let audio, _):
            let scope = ids == nil ? String(localized: "「\(connection?.name ?? "")」中所有云端备份") : String(localized: "这通电话的云端副本")
            let kind = audio ? String(localized: "录音") : String(localized: "图片")
            return String(localized: "将从\(scope)删除\(kind)，文字和摘要保留，本机记录里的\(kind)也保留。之后同步不会再上传这些\(kind)；需要时可在单通详情里重新上传。")
        case .reupload: return String(localized: "把本机这通电话的图片上传到云端；已开启录音同步时，也会上传本机录音。之后同步恢复正常。")
        case nil: return ""
        }
    }

    @ViewBuilder private var confirmationButtons: some View {
        if let confirmation, connection != nil {
            Button("确认", role: confirmation.isDestructive ? .destructive : nil) { perform(confirmation) }
                .disabled(sync.isBusy || isCallActive)
        }
        Button("取消", role: .cancel) { confirmation = nil }
    }

    private func perform(_ confirmation: Confirmation) {
        guard let connection else { return }
        switch confirmation {
        case .destination: run { await sync.refresh(connection: connection, confirmDestinationChange: true) }
        case .media: save { try sync.setMediaEnabled(true) }
        case .delete(let id): run { await sync.deleteRemote(connection: connection, id: id) }
        case .deleteAll(let selectedConnection, let selection):
            run { await sync.deleteAllRemote(connection: selectedConnection, selection: selection) }
        case .useLocal(let id):
            run {
                do { try sync.setTextSyncEnabled(true) }
                catch { loadingError = error.localizedDescription; return }
                await sync.useLocal(connection: connection, id: id)
            }
        case .restore(let id, let media): run { await sync.restore(connection: connection, id: id, includeMedia: media) }
        case .discard: run { await sync.discardPending(connection: connection) }
        case .removeMedia(let ids, let audio, let images):
            run { await sync.removeCloudMedia(connection: connection, ids: ids, audio: audio, images: images) }
        case .reupload(let id):
            run { await sync.reuploadLocalMedia(connection: connection, id: id) }
        }
        self.confirmation = nil
    }

    private func save(_ body: () throws -> Void) {
        do { try body() } catch { loadingError = error.localizedDescription }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        operation = Task {
            defer { operation = nil }
            await body()
        }
    }

}

private struct CloudImagePreview: Identifiable {
    let id = UUID()
    let data: Data
}
