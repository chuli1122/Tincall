// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

@MainActor @Observable
final class CloudSyncStore {
    private(set) var selectedConnectionID: UUID?
    private(set) var textSyncEnabled = false
    private(set) var automaticSyncEnabled = false
    private(set) var mediaEnabled = false
    private(set) var isBusy = false
    private(set) var status = String(localized: "尚未连接云端")
    private(set) var errorMessage: String?
    private(set) var remoteRecords: [CloudSyncRemote] = []
    private(set) var conflicts: Set<UUID> = []
    private(set) var hasPendingOperation = false
    private(set) var canDiscardPending = false
    private(set) var connected = false
    private(set) var requiresDestinationConfirmation = false
    @ObservationIgnored private let records: CallRecordStore
    @ObservationIgnored private let client: CloudSyncClient
    @ObservationIgnored private let connector = ExternalCallClient()
    @ObservationIgnored private let transfer: CloudRecordTransfer
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var state: State
    @ObservationIgnored private var scope: Int?

    private struct AutomaticRetry: Codable {
        let endpoint: String
        let attempts: Int
        let retryAfter: Date
    }

    private struct State: Codable {
        var selectedConnectionID: UUID?
        var textSyncEnabled = false
        var automaticSyncEnabled = false
        var ledgers: [CloudSyncLedger] = []
        var automaticRetries: [String: AutomaticRetry] = [:]
        var confirmedScopes: [String: Int] = [:]

        private enum CodingKeys: String, CodingKey {
            case selectedConnectionID, textSyncEnabled, automaticSyncEnabled, ledgers, automaticRetries, confirmedScopes
        }

        init() { }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            selectedConnectionID = try values.decodeIfPresent(UUID.self, forKey: .selectedConnectionID)
            textSyncEnabled = try values.decodeIfPresent(Bool.self, forKey: .textSyncEnabled) ?? false
            // Prior manual-sync consent never authorizes automatic uploads.
            automaticSyncEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticSyncEnabled) ?? false
            ledgers = try values.decodeIfPresent([CloudSyncLedger].self, forKey: .ledgers) ?? []
            automaticRetries = try values.decodeIfPresent([String: AutomaticRetry].self, forKey: .automaticRetries) ?? [:]
            confirmedScopes = try values.decodeIfPresent([String: Int].self, forKey: .confirmedScopes) ?? [:]
        }
    }

    init(records: CallRecordStore, credentials: CredentialStore = CredentialStore(), directory: URL? = nil) throws {
        self.records = records
        let client = CloudSyncClient(credentials: credentials)
        self.client = client
        transfer = CloudRecordTransfer(records: records, client: client)
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Tincall/CloudSync", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("state.json")
        state = FileManager.default.fileExists(atPath: fileURL.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL)) : State()
        selectedConnectionID = state.selectedConnectionID
        textSyncEnabled = state.textSyncEnabled
        automaticSyncEnabled = state.automaticSyncEnabled
    }

    func select(_ id: UUID?) throws {
        guard !isBusy else { return }
        var next = state; next.selectedConnectionID = id
        try persist(next)
        selectedConnectionID = id
        scope = nil; connected = false; mediaEnabled = false; hasPendingOperation = false; canDiscardPending = false
        remoteRecords = []; conflicts = []; status = String(localized: "尚未连接云端")
    }

    func setTextSyncEnabled(_ enabled: Bool) throws {
        var next = state; next.textSyncEnabled = enabled
        if !enabled { next.automaticSyncEnabled = false }
        try persist(next)
        textSyncEnabled = enabled
        automaticSyncEnabled = next.automaticSyncEnabled
    }

    func setAutomaticSyncEnabled(_ enabled: Bool) throws {
        var next = state
        next.automaticSyncEnabled = enabled
        if enabled { next.textSyncEnabled = true }
        try persist(next)
        automaticSyncEnabled = enabled
        textSyncEnabled = next.textSyncEnabled
    }

    /// Local removal must never become an automatic overwrite of an existing cloud copy.
    /// Reuse the deletion checkpoint: a surviving, different local record requires explicit conflict resolution.
    func prepareLocalDataRemoval(recordIDs: Set<UUID>, category: CallRecordStore.LocalDataCategory) throws {
        try records.requireCompleteLoading()
        guard !isBusy else { throw TincallError(message: String(localized: "正在同步云端，请完成后再清理本机数据。")) }
        guard !recordIDs.isEmpty else { return }
        var next = state
        for index in next.ledgers.indices {
            if let pending = next.ledgers[index].pending, recordIDs.contains(pending.recordID) {
                throw TincallError(message: String(localized: "这些记录仍有未完成的云端操作，请先继续或清理该操作。"))
            }
            if category == .audio || category == .records {
                next.ledgers[index].locallyClearedAudio = (next.ledgers[index].locallyClearedAudio ?? []).union(recordIDs)
            }
            // Audio indexes are local-only; clearing them does not change the synchronized text document.
            guard category != .audio else { continue }
            for id in recordIDs {
                // Without a prior checkpoint, an image edit already conflicts with a different remote copy.
                // Keep new, never-backed-up local calls eligible for their first upload.
                guard category == .records || next.ledgers[index].checkpoints[id] != nil else { continue }
                var checkpoint = next.ledgers[index].checkpoints[id] ?? CloudSyncCheckpoint(revision: 0, text: nil)
                checkpoint.localRemoved = true
                next.ledgers[index].checkpoints[id] = checkpoint
            }
        }
        try persist(next)
    }

    func setMediaEnabled(_ enabled: Bool) throws {
        guard let scope else { throw TincallError(message: String(localized: "请先检查同步目标，再确认媒体备份")) }
        var next = state; next.ledgers[scope].mediaConsent = enabled
        try persist(next)
        mediaEnabled = enabled
    }

    @discardableResult
    func refresh(connection: ConnectionProfile, confirmDestinationChange: Bool = false) async -> Bool {
        await perform {
            try await self.bind(connection, allowDestinationChange: confirmDestinationChange)
            self.remoteRecords = try await self.client.list(connection: connection)
            self.sortRemote()
            try self.clearAutomaticRetry(connection)
            self.status = String(localized: "已连接云端，共 \(self.remoteRecords.count) 通记录。尚未上传本机内容。")
        }
        return requiresDestinationConfirmation
    }

    func synchronize(connection: ConnectionProfile) async {
        await perform {
            try await self.synchronizeContents(connection: connection)
            try self.clearAutomaticRetry(connection)
        }
    }

    func synchronizeAutomatically(connection: ConnectionProfile) async {
        guard automaticSyncEnabled, selectedConnectionID == connection.id else { return }
        await perform(automaticConnection: connection) {
            self.client.isAutomaticSync = true
            defer { self.client.isAutomaticSync = false }
            try self.requireAutomaticSync(connection)
            try await self.bind(connection)
            try self.requireAutomaticSync(connection)
            if self.ledger.pending != nil {
                try await self.resumePending(connection, automatically: true)
            }
            try self.requireAutomaticSync(connection)
            try await self.synchronizeContents(connection: connection, automatically: true)
            let textStatus = self.status
            try self.requireAutomaticSync(connection)
            if self.mediaEnabled {
                try await self.backupMediaContents(connection: connection, automatically: true)
                try self.requireAutomaticSync(connection)
                guard self.mediaEnabled else { throw CancellationError() }
                for remote in self.remoteRecords where !remote.deleted && !self.conflicts.contains(remote.id) {
                    try self.requireAutomaticSync(connection)
                    guard self.mediaEnabled else { throw CancellationError() }
                    guard self.ledger.locallyClearedAudio?.contains(remote.id) != true,
                          self.canSynchronizeRecord(remote.id), let document = remote.record,
                          !document.media.isEmpty,
                          let local = self.records.records.first(where: { $0.id == remote.id }),
                          CloudSyncDocument.textOnly(local) == document.call else { continue }
                    try await self.restoreMedia(connection, document: document, automatically: true)
                }
                self.status = String(localized: "自动同步已完成，录音按此目标的授权同步。待处理冲突：\(self.conflicts.count) 通。")
            } else {
                self.status = textStatus
            }
        }
    }

    private func requireAutomaticSync(_ connection: ConnectionProfile) throws {
        try Task.checkCancellation()
        guard automaticSyncEnabled, textSyncEnabled, selectedConnectionID == connection.id else {
            throw CancellationError()
        }
    }

    private func synchronizeContents(connection: ConnectionProfile, automatically: Bool = false) async throws {
        try await self.bind(connection)
        // Retry connector summaries independently of the optional backup document.
        self.status = String(localized: "正在回传尚未上传的通话摘要…")
        for id in self.records.records.map(\.id) {
            try Task.checkCancellation()
            if automatically { try self.requireAutomaticSync(connection) }
            guard self.canSynchronizeRecord(id),
                  let record = self.records.records.first(where: { $0.id == id }) else { continue }
            await connector.uploadSummary(for: record, connection: connection)
        }
        guard self.textSyncEnabled else { throw TincallError(message: String(localized: "请先启用文字和摘要同步")) }
        try self.requireNoPending()
        self.status = String(localized: "正在检查云端记录版本…")
        let indexes = try await self.client.list(connection: connection)
        self.remoteRecords = indexes; self.conflicts = []
        let ids = Set(indexes.map(\.id)).union(self.records.records.map(\.id))
        var uploaded = 0; var downloaded = 0; var deferred = 0
        for (position, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            try Task.checkCancellation()
            if automatically { try self.requireAutomaticSync(connection) }
            guard self.canSynchronizeRecord(id) else { deferred += 1; continue }
            let checkpoint = self.ledger.checkpoints[id]
            let index = indexes.first { $0.id == id }
            // The list carries server revisions. With audio sync off, unchanged text
            // needs neither a full-record request nor another checkpoint write.
            if !self.mediaEnabled, let index, let checkpoint,
               index.revision == checkpoint.revision, index.deleted == checkpoint.deleted {
                let local = self.records.records.first { $0.id == id }
                if index.deleted || (checkpoint.localRemoved && local == nil) { continue }
                if !checkpoint.localRemoved, let local,
                   CloudSyncDocument.textOnly(local) == checkpoint.text { continue }
            }
            self.status = String(localized: "正在同步通话记录：\(position + 1)／\(ids.count)…")
            let remote = index == nil ? nil : try await self.client.get(connection: connection, id: id)
            if let remote { self.replaceRemote(remote) }
            // Re-read after the network await: background summary work may have saved new text.
            try Task.checkCancellation()
            if automatically { try self.requireAutomaticSync(connection) }
            guard self.canSynchronizeRecord(id) else { deferred += 1; continue }
            let current = self.records.records.first { $0.id == id }
            switch CloudSyncDecision.decide(local: current, remote: remote, checkpoint: checkpoint) {
            case .upload:
                guard let current else { continue }
                let media = remote?.record?.media ?? []
                guard media.allSatisfy({ item in current.messages.contains { $0.id == item.asset.messageID } }) else {
                    self.conflicts.insert(id); continue
                }
                try await self.submit(connection, id: id, revision: remote?.revision ?? 0, document: CloudSyncDocument(call: current, media: media, imageReferences: remote?.record?.imageReferences), automatically: automatically)
                uploaded += 1
            case .download:
                guard let remote, let document = remote.record else { continue }
                if let current, current.audioAssets.contains(where: { asset in !document.call.messages.contains { $0.id == asset.messageID } }) {
                    self.conflicts.insert(id); continue
                }
                try await self.installText(document, connection: connection, automatically: automatically)
                try self.remember(remote)
                downloaded += 1
            case .unchanged:
                if let remote { try self.remember(remote) }
            case .cloudDeleted:
                if let remote { try self.remember(remote) }
            case .locallyRemoved:
                if let remote {
                    var next = self.state
                    next.ledgers[self.scope!].checkpoints[id] = CloudSyncCheckpoint(revision: remote.revision, text: checkpoint?.text, deleted: false, localRemoved: true)
                    try self.persist(next)
                }
            case .conflict: self.conflicts.insert(id)
            }
        }
        self.sortRemote()
        self.status = String(localized: "通话内容：上传 \(uploaded) 通，下载／更新 \(downloaded) 通，冲突 \(self.conflicts.count) 通。")
        if deferred > 0 {
            self.status += String(localized: "另有 \(deferred) 通正在通话或处理待办，暂未同步。")
        }
    }

    func useLocal(connection: ConnectionProfile, id: UUID) async {
        await perform {
            guard self.textSyncEnabled else { throw TincallError(message: String(localized: "请先启用手动文字同步")) }
            try await self.bind(connection)
            try self.requireNoPending()
            let remote = try await self.client.get(connection: connection, id: id)
            try self.requireIdleRecord(id)
            guard let local = self.records.records.first(where: { $0.id == id }) else {
                throw TincallError(message: String(localized: "找不到已结束的本机通话"))
            }
            let media = remote?.record?.media ?? []
            guard media.allSatisfy({ item in local.messages.contains { $0.id == item.asset.messageID } }) else {
                throw TincallError(message: String(localized: "云端含本机没有的音频消息，请先恢复云端副本再处理"))
            }
            try await self.submit(connection, id: id, revision: remote?.revision ?? 0, document: CloudSyncDocument(call: local, media: media, imageReferences: remote?.record?.imageReferences))
            self.conflicts.remove(id)
            self.status = String(localized: "已按选择用本机文字更新云端；未上传录音")
        }
    }

    func restore(connection: ConnectionProfile, id: UUID, includeMedia: Bool = false) async {
        await perform {
            try await self.bind(connection)
            try self.requireNoPending()
            guard let remote = try await self.client.get(connection: connection, id: id), !remote.deleted, let document = remote.record else {
                throw TincallError(message: String(localized: "云端副本已删除或不存在"))
            }
            if includeMedia, !self.mediaEnabled { throw TincallError(message: String(localized: "请先确认此目标的媒体备份与下载说明")) }
            try self.requireIdleRecord(id)
            let local = self.records.records.first { $0.id == id }
            if let local, CloudSyncDocument.textOnly(local) != document.call {
                try self.transfer.preserveLocalCopy(local)
            }
            try await self.installText(document, connection: connection)
            if includeMedia {
                try await self.restoreMedia(connection, document: document)
                var next = self.state
                next.ledgers[self.scope!].locallyClearedAudio?.remove(id)
                try self.persist(next)
            }
            try self.remember(remote)
            self.replaceRemote(remote); self.conflicts.remove(id)
            self.status = includeMedia ? String(localized: "已恢复文字和云端已有录音；不同的本机文字已另存副本") : String(localized: "已恢复云端文字；不同的本机文字已另存副本，未下载录音")
        }
    }

    func deleteRemote(connection: ConnectionProfile, id: UUID) async {
        await perform {
            try await self.bind(connection)
            try self.requireNoPending()
            guard let remote = try await self.client.get(connection: connection, id: id) else { return }
            if remote.deleted { try self.remember(remote); return }
            try await self.submit(connection, id: id, revision: remote.revision, document: nil)
            self.conflicts.remove(id)
            self.status = String(localized: "已删除云端副本与媒体；本机记录保留，后续同步不会自动回传")
        }
    }

    /// Fetch the exact selection before presenting its count for confirmation.
    func backupsForDeletion(connection: ConnectionProfile) async -> [CloudSyncRemote]? {
        var selection: [CloudSyncRemote]?
        await perform {
            try await self.bind(connection)
            try self.requireNoPending()
            try self.requireBackupOnlyDeletion()
            let indexes = try await self.client.list(connection: connection)
            self.remoteRecords = indexes
            self.sortRemote()
            let candidates = indexes.filter { !$0.deleted }
            for remote in candidates { try self.requireIdleRecord(remote.id) }
            if candidates.isEmpty { self.status = String(localized: "当前云端没有可清空的备份。") }
            selection = candidates
        }
        return selection
    }

    func deleteAllRemote(connection: ConnectionProfile, selection: [CloudSyncRemote]) async {
        await perform {
            try await self.bind(connection)
            try self.requireNoPending()
            try self.requireBackupOnlyDeletion()
            // Keep the confirmed IDs and revisions: new records are not part of this deletion.
            for remote in selection { try self.requireIdleRecord(remote.id) }
            var deleted = 0
            do {
                for remote in selection {
                    try Task.checkCancellation()
                    try self.requireIdleRecord(remote.id)
                    self.status = String(localized: "正在清空云端备份：已删除 \(deleted)／\(selection.count) 通。")
                    try await self.submit(connection, id: remote.id, revision: remote.revision, document: nil, preserveCallMedia: true)
                    self.conflicts.remove(remote.id)
                    deleted += 1
                    self.status = String(localized: "正在清空云端备份：已删除 \(deleted)／\(selection.count) 通。")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                throw TincallError(message: String(localized: "清空未完成：已确认删除 \(deleted)／\(selection.count) 通。请处理错误后继续。") + "\n" + error.localizedDescription)
            }
            self.status = String(localized: "已清空 \(deleted) 通云端备份；本机记录、MCP 通话和来电计划保留。已删除的记录不会随同步重新上传。")
        }
    }

    private func requireBackupOnlyDeletion() throws {
        guard client.supportsBackupOnlyDeletion else {
            throw TincallError(message: String(localized: "当前云端尚不支持安全清空备份，请先更新云端服务。"))
        }
    }

    func backupMedia(connection: ConnectionProfile) async {
        await perform { try await self.backupMediaContents(connection: connection) }
    }

    private func backupMediaContents(connection: ConnectionProfile, automatically: Bool = false) async throws {
        try await self.bind(connection)
        guard self.mediaEnabled else { throw TincallError(message: String(localized: "请先确认此目标的媒体备份说明")) }
        try self.requireNoPending()
        var count = 0
        let ids = self.records.records.filter { $0.isFinished && !$0.audioAssets.isEmpty }.map(\.id)
        for id in ids {
            try Task.checkCancellation()
            if automatically {
                try self.requireAutomaticSync(connection)
                guard self.mediaEnabled else { throw CancellationError() }
                if self.conflicts.contains(id) || !self.canSynchronizeRecord(id) { continue }
            }
            try self.requireIdleRecord(id)
            let remote = try await self.client.get(connection: connection, id: id)
            try Task.checkCancellation()
            if automatically {
                try self.requireAutomaticSync(connection)
                guard self.mediaEnabled else { throw CancellationError() }
            }
            try self.requireIdleRecord(id)
            guard let local = self.records.records.first(where: { $0.id == id }) else { continue }
            guard let remote, !remote.deleted,
                  let document = remote.record, document.call == CloudSyncDocument.textOnly(local) else {
                if automatically { continue }
                throw TincallError(message: String(localized: "请先同步文字并处理冲突，再备份已有录音"))
            }
            let backup = try self.transfer.prepareBackup(local, document: document)
            let uploads = backup.uploads
            guard !uploads.isEmpty else { continue }
            let pending = CloudSyncPending(requestID: UUID(), recordID: local.id, expectedRevision: remote.revision, document: backup.document, uploads: uploads)
            try self.savePending(pending)
            try await self.resumePending(connection, automatically: automatically)
            count += uploads.count
        }
        self.status = String(localized: "已备份 \(count) 段此前保留的录音；没有开启新的录音")
    }

    func continuePending(connection: ConnectionProfile) async {
        await perform {
            try await self.bind(connection)
            try await self.resumePending(connection)
            try self.clearAutomaticRetry(connection)
            self.status = String(localized: "上次云端操作已完成")
        }
    }

    func clearError() { errorMessage = nil }

    /// Cloud writes must not race a coordinator or summary task holding an older copy.
    func canSynchronizeRecord(_ id: UUID) -> Bool {
        guard records.canModifyRecord(id) else { return false }
        guard records.canDeleteRecord?(id) != false else { return false }
        guard let local = records.records.first(where: { $0.id == id }) else { return true }
        return local.isFinished && local.summaryStatus != .pending && local.summaryStatus != .generating &&
            local.externalPendingInput == nil && local.externalPendingControl == nil
    }

    private func requireIdleRecord(_ id: UUID) throws {
        try records.requireCompleteLoading()
        guard canSynchronizeRecord(id) else {
            throw TincallError(message: String(localized: "此通话仍在进行、生成摘要或保存，请完成后再同步或恢复"))
        }
    }

    private var ledger: CloudSyncLedger { state.ledgers[scope!] }

    private func bind(_ connection: ConnectionProfile, allowDestinationChange: Bool = false) async throws {
        let remembered = state.confirmedScopes[connection.id.uuidString].flatMap { index in
            state.ledgers.indices.contains(index) && state.ledgers[index].connectionID == connection.id ? index : nil
        }
        let previous = (scope ?? remembered).map { state.ledgers[$0] }
            ?? state.ledgers.last(where: { $0.connectionID == connection.id })
        let owner = try await client.owner(connection: connection)
        guard let endpoint = connection.endpoint?.absoluteString else { throw TincallError(message: String(localized: "云端地址缺失")) }
        if let previous, previous.connectionID != connection.id || previous.endpoint != endpoint || previous.ownerID != owner {
            remoteRecords = []; conflicts = []; connected = false
            if !allowDestinationChange {
                requiresDestinationConfirmation = true
                throw TincallError(message: String(localized: "同步目标或所属账户已变更，请重新读取云端列表后操作"))
            }
        }
        var next = state
        let index: Int
        if let existing = state.ledgers.firstIndex(where: { $0.connectionID == connection.id && $0.endpoint == endpoint && $0.ownerID == owner }) {
            index = existing
        } else {
            next.ledgers.append(CloudSyncLedger(connectionID: connection.id, endpoint: endpoint, ownerID: owner))
            index = next.ledgers.count - 1
        }
        if next.confirmedScopes[connection.id.uuidString] != index {
            next.confirmedScopes[connection.id.uuidString] = index
            try persist(next)
        }
        scope = index
        connected = true
        mediaEnabled = ledger.mediaConsent
        hasPendingOperation = ledger.pending != nil
        canDiscardPending = ledger.pending.map { !$0.isDelete && (!$0.manifestAttempted || $0.revisionRejected) } ?? false
    }

    private func submit(_ connection: ConnectionProfile, id: UUID, revision: Int, document: CloudSyncDocument?, automatically: Bool = false, preserveCallMedia: Bool? = nil) async throws {
        var pending = CloudSyncPending(requestID: UUID(), recordID: id, expectedRevision: revision, document: document)
        pending.preserveCallMedia = preserveCallMedia
        try savePending(pending)
        try await resumePending(connection, automatically: automatically)
    }

    private func savePending(_ pending: CloudSyncPending?) throws {
        try records.requireCompleteLoading()
        var next = state
        next.ledgers[scope!].pending = pending
        try persist(next)
        hasPendingOperation = pending != nil
        canDiscardPending = pending.map { !$0.isDelete && (!$0.manifestAttempted || $0.revisionRejected) } ?? false
    }

    private func requireNoPending() throws {
        guard ledger.pending == nil else {
            throw TincallError(message: String(localized: "上次云端操作尚未确认，请先选择继续或清理，再开始新操作"))
        }
    }

    private func resumePending(_ connection: ConnectionProfile, automatically: Bool = false) async throws {
        try records.requireCompleteLoading()
        guard var pending = ledger.pending else { return }
        guard !pending.revisionRejected else { throw TincallError(message: String(localized: "上次写入因冲突或权限被拒绝，请先清理未提交的操作，再刷新处理")) }
        if !pending.uploads.isEmpty, !mediaEnabled { throw TincallError(message: String(localized: "上次媒体备份未完成，请重新确认媒体权限后继续")) }
        while pending.uploadedCount < pending.uploads.count {
            try Task.checkCancellation()
            if automatically { try requireAutomaticSync(connection) }
            guard mediaEnabled else { throw CancellationError() }
            try requireIdleRecord(pending.recordID)
            let media = pending.uploads[pending.uploadedCount]
            try await transfer.upload(media, recordID: pending.recordID, connection: connection)
            try Task.checkCancellation()
            if automatically { try requireAutomaticSync(connection) }
            guard mediaEnabled else { throw CancellationError() }
            pending.uploadedCount += 1
            try savePending(pending)
        }
        if !pending.isDelete { try requireIdleRecord(pending.recordID) }
        let images = try transfer.images(in: pending.document, recordID: pending.recordID)
        try Task.checkCancellation()
        if automatically { try requireAutomaticSync(connection) }
        if !pending.uploads.isEmpty, !mediaEnabled { throw CancellationError() }
        pending.manifestAttempted = true
        try savePending(pending)
        do {
            let remote = try await client.mutate(connection: connection, pending: pending, images: images)
            var next = state
            next.ledgers[scope!].pending = nil
            next.ledgers[scope!].checkpoints[remote.id] = CloudSyncCheckpoint(revision: remote.revision, text: pending.document?.call, deleted: remote.deleted)
            try persist(next)
            hasPendingOperation = false; canDiscardPending = false
            replaceRemote(remote)
        } catch let failure as CloudSyncFailure where (400..<500).contains(failure.status) {
            // A definitive rejection did not publish this manifest. Keep the journal
            // until any uploaded, unreferenced media have been explicitly cleaned up.
            if failure.code == "revision_conflict" || failure.code == "operation_retired" { conflicts.insert(pending.recordID) }
            let hasImages = pending.document?.call.messages.contains { $0.images?.isEmpty == false } == true
            if pending.isDelete, pending.preserveCallMedia == true, failure.code == "revision_conflict" { try savePending(nil) }
            else if pending.uploads.isEmpty, !hasImages, !pending.isDelete { try savePending(nil) }
            else if !pending.isDelete { pending.revisionRejected = true; try savePending(pending) }
            throw failure
        }
    }

    func discardPending(connection: ConnectionProfile) async {
        await perform {
            try await self.bind(connection)
            guard let pending = self.ledger.pending else { return }
            guard !pending.isDelete, !pending.manifestAttempted || pending.revisionRejected else {
                throw TincallError(message: String(localized: "服务器是否已提交尚不确定，请继续上次操作以确认结果"))
            }
            let remote = try await self.client.get(connection: connection, id: pending.recordID)
            var referenced = Set((remote?.record?.media.map(\.object_id) ?? []) + (remote?.record?.imageReferences?.map(\.id) ?? []))
            if pending.document?.call.messages.contains(where: { $0.images?.isEmpty == false }) == true {
                referenced.formUnion(try await self.client.callImageIDs(connection: connection, callID: pending.recordID))
            }
            let objects = Set(pending.uploads.map(\.object_id) + (pending.document?.call.messages.flatMap { ($0.images ?? []).map(\.id) } ?? []))
            for objectID in objects where !referenced.contains(objectID) {
                do { try await self.client.removeMedia(connection: connection, recordID: pending.recordID, objectID: objectID) }
                catch let failure as CloudSyncFailure where failure.status == 404 || failure.status == 410 { }
            }
            try self.savePending(nil)
            self.status = String(localized: "已清理未提交的操作；本机记录和已发布云端内容保留")
        }
    }

    private func remember(_ remote: CloudSyncRemote) throws {
        try records.requireCompleteLoading()
        var next = state
        next.ledgers[scope!].checkpoints[remote.id] = CloudSyncCheckpoint(revision: remote.revision, text: remote.record?.call, deleted: remote.deleted)
        try persist(next)
    }

    private func installText(_ document: CloudSyncDocument, connection: ConnectionProfile, automatically: Bool = false) async throws {
        try await transfer.installText(document, connection: connection) {
            if automatically { try self.requireAutomaticSync(connection) }
            try self.requireIdleRecord(document.call.id)
        }
    }

    private func restoreMedia(_ connection: ConnectionProfile, document: CloudSyncDocument, automatically: Bool = false) async throws {
        try await transfer.restoreMedia(connection, document: document) {
            if automatically { try self.requireAutomaticSync(connection) }
            guard self.mediaEnabled else { throw CancellationError() }
            try self.requireIdleRecord(document.call.id)
        }
    }

    private func persist(_ next: State) throws {
        let data = try JSONEncoder().encode(next)
        guard data.count <= 64 * 1024 * 1024 else { throw TincallError(message: String(localized: "云端同步索引超过本机大小限制")) }
        try data.write(to: fileURL, options: .atomic)
        state = next
    }

    private func replaceRemote(_ remote: CloudSyncRemote) {
        remoteRecords.removeAll { $0.id == remote.id }
        remoteRecords.append(remote)
    }

    private func sortRemote() { remoteRecords.sort { $0.updated_at > $1.updated_at } }

    private func clearAutomaticRetry(_ connection: ConnectionProfile) throws {
        guard state.automaticRetries[connection.id.uuidString] != nil else { return }
        var next = state
        next.automaticRetries.removeValue(forKey: connection.id.uuidString)
        try persist(next)
    }

    private func perform(automaticConnection: ConnectionProfile? = nil, _ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        guard records.storageIssue == nil else {
            errorMessage = records.storageIssue
            status = String(localized: "本机记录未能完整读取，云端同步已暂停。")
            return
        }
        if let connection = automaticConnection, let retry = state.automaticRetries[connection.id.uuidString],
           retry.endpoint == connection.endpoint?.absoluteString, retry.retryAfter > Date() { return }
        isBusy = true; errorMessage = nil; requiresDestinationConfirmation = false
        status = String(localized: "正在连接云端…")
        defer { isBusy = false }
        do {
            try Task.checkCancellation()
            // Missing local files cannot be interpreted as deliberate deletion,
            // even when the cloud ledger has an older checkpoint or pending write.
            try records.requireCompleteLoading()
            try await operation()
            if let connection = automaticConnection { try clearAutomaticRetry(connection) }
        }
        catch is CancellationError { status = String(localized: "操作已暂停，已保存的本机内容和待完成请求保留") }
        catch {
            if let conflict = error as? CloudRecordTransfer.Conflict { conflicts.insert(conflict.recordID) }
            errorMessage = requiresDestinationConfirmation ? nil : error.localizedDescription
            status = String(localized: "操作未完成，请查看错误后处理")
            if let connection = automaticConnection {
                let endpoint = connection.endpoint?.absoluteString ?? ""
                let previous = state.automaticRetries[connection.id.uuidString]
                let attempts = min((previous?.endpoint == endpoint ? previous?.attempts ?? 0 : 0) + 1, 7)
                var next = state
                next.automaticRetries[connection.id.uuidString] = AutomaticRetry(endpoint: endpoint, attempts: attempts,
                    retryAfter: Date().addingTimeInterval(min(60 * pow(2, Double(attempts - 1)), 3600)))
                do { try persist(next) }
                catch { errorMessage = String(localized: "自动同步失败，且重试状态未保存：\(error.localizedDescription)") }
            }
        }
    }
}
