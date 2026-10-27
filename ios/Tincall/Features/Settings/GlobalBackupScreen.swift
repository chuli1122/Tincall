// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UniformTypeIdentifiers

struct GlobalBackupScreen: View {
    let configuration: LocalConfigurationStore
    let records: CallRecordStore
    let isCallActive: Bool
    var cloudSync: CloudSyncStore? = nil
    var cloudSyncLoadingError: String? = nil
    @State private var document: GlobalBackupDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var storageUsage: CallRecordStore.StorageUsage?
    @State private var configurationBytes: Int64?
    @State private var storageError: String?
    @State private var cleanupCategory: CallRecordStore.LocalDataCategory?

    var body: some View {
        SettingsList {
            Section {
                LabeledContent("联系人", value: "\(configuration.roles.count)")
                LabeledContent("通话记录", value: "\(records.records.count)")
                LabeledContent("通话文字", value: formattedBytes(storageUsage?.textBytes))
                LabeledContent("消息图片", value: formattedBytes(storageUsage?.imageBytes))
                LabeledContent("已保存录音", value: String(localized: "\(records.records.reduce(0) { $0 + $1.audioAssets.count }) 段") + " · " + formattedBytes(storageUsage?.audioBytes))
                LabeledContent("配置数据", value: formattedBytes(configurationBytes))
                if let storageError {
                    Text("无法统计本机数据大小：\(storageError)").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { SettingsSectionHeading(title: String(localized: "本机数据"), caption: "ON THIS IPHONE") } footer: {
                Text("按本机文件大小统计。配置数据包含联系人、连接设置、头像和通话背景；这里不包含请求日志、导入字体和缓存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("保存录音", isOn: Binding(get: {
                    configuration.retention.user || configuration.retention.assistant
                }, set: { enabled in
                    saveRetention(AudioRetention(user: enabled, assistant: enabled))
                }))
                if configuration.retention.user || configuration.retention.assistant {
                    Toggle("保存我的声音", isOn: retentionBinding(user: true))
                    Toggle("保存对方声音", isOn: retentionBinding(user: false))
                }
            } header: { SettingsSectionHeading(title: String(localized: "录音存储"), caption: "AUDIO") } footer: {
                Text("默认关闭。开启后可分别选择两方声音；关闭只停止保存后续录音，已有录音和文字记录会保留。数据保存在本机。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                cleanupButton(.audio, title: String(localized: "清理所有录音"), detail: String(localized: "保留通话文字、摘要和图片"))
                cleanupButton(.images, title: String(localized: "清理所有消息图片"), detail: String(localized: "保留通话文字、摘要和录音"))
                cleanupButton(.records, title: String(localized: "清理全部通话记录"), detail: String(localized: "删除文字、摘要、图片和录音"))
            } header: { SettingsSectionHeading(title: String(localized: "清理本机数据"), caption: "CLEAN UP") } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if cloudSync?.isBusy == true {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在同步云端，请完成后再清理本机数据。")
                        }
                    }
                    Text("每项单独确认，清理后无法撤销。联系人、连接配置、云端副本及已导出文件保留。若清理后的内容与云端不同，后续同步需手动选择保留哪一份。通话、导入或云端同步期间不可清理。")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(isCallActive || isWorking || isExporting || isImporting)
            Group {
                Section {
                    Button {
                        guard !isCallActive, !isWorking, !isExporting, !isImporting else { return }
                        isWorking = true
                        Task {
                            defer { isWorking = false }
                            do {
                                let value = try await GlobalBackup.export(configuration: configuration, records: records)
                                guard !Task.isCancelled else { return }
                                document = GlobalBackupDocument(export: value)
                                isExporting = true
                            } catch { message = String(localized: "导出失败：\(error.localizedDescription)") }
                        }
                    } label: { SettingsActionLabel(title: String(localized: "导出备份文件夹"), symbol: "square.and.arrow.up", detail: String(localized: "保存联系人、通话记录与连接配置")) }
                    .buttonStyle(.plain)
                    Button { isImporting = true } label: {
                        SettingsActionLabel(title: String(localized: "导入备份文件夹"), symbol: "square.and.arrow.down", detail: String(localized: "合并到本机，保留已有内容"))
                    }
                    .buttonStyle(.plain)
                } header: { SettingsSectionHeading(title: String(localized: "备份文件"), caption: "BACKUP FILES") } footer: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("导出：保存到你选择的位置，无需云端。包含联系人、连接配置、头像、通话背景、文字、消息图片、摘要和已保存录音；不包含 API Key 与访问令牌，换设备后需要重新填写。")
                        Text("导入：选择完整备份文件夹，合并到本机。同一通话只导入一次，已有记录保留本机版本。备份大小和记录数量不设固定上限，请确保本机有足够的剩余空间。")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if isCallActive { Text("请结束通话后再导出或导入。") }
                if isWorking { ProgressView("正在导入…") }
            }
            .disabled(isCallActive || isWorking)
        }
        .modifier(SettingsPageStyle(title: String(localized: "本机数据与备份"), subtitle: String(localized: "存储用量 · 录音保存 · 备份文件"), symbol: "archivebox", index: "YOUR ARCHIVE"))
        .task { refreshStorageUsage() }
        .alert(cleanupTitle, isPresented: Binding(get: { cleanupCategory != nil }, set: { if !$0 { cleanupCategory = nil } })) {
            Button("清理", role: .destructive) { clearLocalData() }
                .disabled(isCallActive || isWorking || cloudSync?.isBusy == true)
            Button("取消", role: .cancel) { cleanupCategory = nil }
        } message: { Text(cleanupMessage) }
        .fileExporter(isPresented: $isExporting, document: document, contentType: .folder, defaultFilename: String(localized: "Tincall备份")) { result in
            switch result {
            case .success: message = String(localized: "备份文件夹已导出。")
            case .failure(let error): if !isCancellation(error) { message = String(localized: "导出失败：\(error.localizedDescription)") }
            }
            document = nil
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                guard !isCallActive, !isWorking else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                isWorking = true
                Task {
                    defer {
                        if accessed { url.stopAccessingSecurityScopedResource() }
                        isWorking = false
                    }
                    do {
                        let imported = try await GlobalBackup.importFolder(url, configuration: configuration, records: records)
                        message = String(localized: "已导入\(imported.contacts)位联系人、\(imported.connections)个连接和\(imported.records)条记录。已有数据保留。")
                        if imported.skippedRecords > 0 { message! += String(localized: "已跳过\(imported.skippedRecords)条已有通话。") }
                        if imported.temporaryCleanupFailed { message! += String(localized: "临时副本清理失败。") }
                        refreshStorageUsage()
                    } catch { if !isCancellation(error) { message = String(localized: "导入失败：\(error.localizedDescription)") } }
                }
            } catch { if !isCancellation(error) { message = String(localized: "导入失败：\(error.localizedDescription)") } }
        }
        .alert("本机数据与备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func cleanupButton(_ category: CallRecordStore.LocalDataCategory, title: String, detail: String) -> some View {
        Button(role: .destructive) { cleanupCategory = category } label: {
            SettingsActionLabel(title: title, symbol: "trash", detail: detail)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .disabled(!records.records.contains(where: category.contains))
    }

    private var cleanupTitle: String {
        switch cleanupCategory {
        case .audio: String(localized: "清理本机所有录音？")
        case .images: String(localized: "清理本机所有消息图片？")
        case .records: String(localized: "清理本机全部通话记录？")
        case nil: String(localized: "清理本机数据")
        }
    }

    private var cleanupMessage: String {
        let detail: String
        switch cleanupCategory {
        case .audio: detail = String(localized: "删除已保存的双方录音，保留通话文字、摘要和图片。录音保存开关不变。")
        case .images: detail = String(localized: "删除消息中的图片，保留通话文字、摘要和录音。")
        case .records: detail = String(localized: "删除全部通话记录及其文字、摘要、图片和录音。")
        case nil: return ""
        }
        var text = detail + "\n\n" + String(localized: "此操作无法撤销。联系人、连接配置、云端副本及已导出文件保留；与云端不同的内容将在同步时等待你手动选择。")
        if cloudSync?.isBusy == true {
            text += "\n\n" + String(localized: "正在同步云端，请完成后再清理本机数据。")
        }
        return text
    }

    private func clearLocalData() {
        guard let category = cleanupCategory else { return }
        cleanupCategory = nil
        guard !isCallActive, !isWorking, !isExporting, !isImporting else {
            message = String(localized: "请结束通话或备份操作后再清理。")
            return
        }
        isWorking = true
        defer { isWorking = false; refreshStorageUsage() }
        do {
            if cloudSyncLoadingError != nil { throw TincallError(message: String(localized: "云端同步状态未能读取，请重新打开 App 后再清理，以保护云端副本。")) }
            let targets = try records.recordsForCleanup(category)
            try cloudSync?.prepareLocalDataRemoval(recordIDs: Set(targets.map(\.id)), category: category)
            try records.clearLocalData(category)
            message = String(localized: "所选本机数据已清理。")
        } catch { message = String(localized: "清理未全部完成：\(error.localizedDescription) 已完成的部分不会撤销。") }
    }

    private func formattedBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshStorageUsage() {
        do {
            let usage = try records.storageUsage()
            let bytes = try configuration.storageBytes()
            storageUsage = usage
            configurationBytes = bytes
            storageError = nil
        } catch {
            storageUsage = nil
            configurationBytes = nil
            storageError = error.localizedDescription
        }
    }

    private func saveRetention(_ retention: AudioRetention) {
        do {
            try configuration.saveRetention(retention)
            refreshStorageUsage()
        }
        catch { message = String(localized: "录音存储设置未保存，请重试。") }
    }

    private func retentionBinding(user: Bool) -> Binding<Bool> {
        Binding(get: { user ? configuration.retention.user : configuration.retention.assistant }, set: { enabled in
            var next = configuration.retention
            if user { next.user = enabled } else { next.assistant = enabled }
            saveRetention(next)
        })
    }

    private func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue
    }
}

struct GlobalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.folder] }
    let export: GlobalBackup.Export

    init(export: GlobalBackup.Export) { self.export = export }

    init(configuration: ReadConfiguration) throws {
        throw TincallError(message: String(localized: "请使用全局导入选择备份文件夹"))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        export.fileWrapper.value
    }
}
