// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

extension CallCoordinator {
    func persistAudio(_ callID: UUID) {
        hasUnsavedAudio = pendingAudio.values.contains { !$0.isEmpty }
        guard let onSaveAudio, let original = records[callID] else { return }
        for segment in pendingAudio[callID] ?? [] {
            guard original.messages.contains(where: { $0.id == segment.messageID }) else { continue }
            do {
                let asset = try onSaveAudio(callID, segment)
                guard var updated = records[callID] else { continue }
                if !updated.audioAssets.contains(where: { $0.id == asset.id }) { updated.audioAssets.append(asset) }
                updated.audioAssets.sort { a, b in
                    if a.messageID == b.messageID { return a.segmentIndex < b.segmentIndex }
                    return a.messageID.uuidString < b.messageID.uuidString
                }
                try save(updated)
                records[callID] = updated
                publish(callID)
                // Ownership transfer: delete only after durable copy and atomic index save succeeded.
                try FileManager.default.removeItem(at: segment.fileURL)
                pendingAudio[callID]?.removeAll { $0.id == segment.id }
                if pendingAudio[callID]?.isEmpty != false, pendingFinalInputs[callID]?.isEmpty != false { savingCallIDs.remove(callID) }
            } catch {
                savingCallIDs.insert(callID)
                if record?.id == callID { errorMessage = String(localized: "录音保存未完成，源文件已保留：\(safeMessage(error))") }
            }
        }
        hasUnsavedAudio = pendingAudio.values.contains { !$0.isEmpty }
    }

    func requestSummary(for value: CallRecord, connections: [ConnectionProfile], roles: [CallRole], using connectionID: UUID? = nil) {
        guard value.isFinished else { errorMessage = String(localized: "请先结束通话再生成摘要"); return }
        guard let role = roles.first(where: { $0.id == value.roleID })
                ?? (connectionID == nil ? nil : CallRole(id: value.roleID, name: value.roleName)) else {
            errorMessage = String(localized: "此记录的联系人已不存在")
            return
        }
        guard let summaryID = connectionID ?? role.summaryConnectionID else {
            errorMessage = String(localized: "此联系人已关闭摘要，请先选择摘要模型预设")
            return
        }
        guard let connection = connections.first(where: { $0.id == summaryID }) else {
            errorMessage = String(localized: "此联系人的摘要模型预设已不存在")
            return
        }
        do { try model.validate(connection) }
        catch { errorMessage = safeMessage(error); return }
        // Keep genuinely active work, but take idle records from storage so manual edits stay intact.
        if records[value.id] == nil || (tasks[value.id] == nil && !summaryTasks.isRunning(value.id) &&
            pendingAudio[value.id]?.isEmpty != false && pendingFinalInputs[value.id]?.isEmpty != false && !savingCallIDs.contains(value.id)) {
            records[value.id] = value
        }
        if let connectorID = value.externalConnectionID {
            externalConnections[value.id] = connections.first { $0.id == connectorID }
        }
        summaryTasks.configure(callID: value.id, role: role, connection: connection)
        requestSummary(callID: value.id)
    }

    private enum Goodbye {
        static let word = "goodbye"
    }

    func resumePendingSummaries(from values: [CallRecord], connections: [ConnectionProfile], roles: [CallRole]) {
        for value in values where value.endedAt != nil && (value.summaryStatus == .pending || value.summaryStatus == .generating) {
            guard !summaryTasks.isRunning(value.id) else { continue }
            requestSummary(for: value, connections: connections, roles: roles)
            if !summaryTasks.isRunning(value.id) {
                if records[value.id] == nil { records[value.id] = value }
                mutate(value.id) { $0.summaryStatus = .failed }
                persist(value.id)
            }
        }
    }

    func canForgetRecord(_ id: UUID) -> Bool {
        session?.callID != id && tasks[id] == nil && !summaryTasks.isRunning(id) &&
        pendingAudio[id]?.isEmpty != false && pendingFinalInputs[id]?.isEmpty != false &&
        records[id]?.externalPendingControl == nil && !savingCallIDs.contains(id)
    }

    /// Call after a successful store deletion. Active work must be disabled by the caller's UI.
    func forgetRecord(_ id: UUID) {
        guard canForgetRecord(id) else { return }
        historyRecords.removeAll { $0.id == id }
        records.removeValue(forKey: id)
        sessions.removeValue(forKey: id)
        turns.removeValue(forKey: id)
        summaryTasks.forget(id)
        externalConnections.removeValue(forKey: id)
        savingCallIDs.remove(id)
        if record?.id == id { record = nil; revision += 1 }
    }

    func requestSummary(callID: UUID) {
        guard !summaryTasks.isRunning(callID), summaryTasks.isConfigured(callID),
              records[callID]?.messages.contains(where: {
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.images?.isEmpty == false
              }) == true else { return }
        mutate(callID) { $0.summaryStatus = .pending }
        do { if let value = records[callID] { try save(value) } }
        catch { reportSavingFailure(error, callID: callID); return }
        summaryTasks.start(callID: callID, after: tasks[callID], userName: summaryUserName(),
                           record: { [weak self] in self?.records[callID] }) { [self] update in
            // Retain the record owner until the final save/upload has completed.
            switch update {
            case .generating:
                self.mutate(callID) { $0.summaryStatus = .generating }
                self.persist(callID)
                return
            case .completed(let summary):
                self.mutate(callID) { $0.summary = summary; $0.summaryStatus = .completed; $0.summaryUploadRequestID = UUID() }
            case .failed(let error):
                self.mutate(callID) { $0.summaryStatus = .failed }
                if self.record?.id == callID { self.errorMessage = String(localized: "通话摘要失败：\(self.safeMessage(error))") }
            }
            self.persist(callID)
            if let value = self.records[callID], let connector = self.externalConnections[callID] {
                await self.external.uploadSummary(for: value, connection: connector)
            }
        }
    }

    func mutate(_ id: UUID, _ update: (inout CallRecord) -> Void) {
        guard var value = records[id] else { return }
        update(&value)
        records[id] = value
        publish(id)
    }

    func publish(_ id: UUID) {
        guard record?.id == id else { return }
        record = records[id]
        revision += 1
    }

    func save(_ value: CallRecord) throws {
        guard let onSaveRecord else { throw TincallError(message: String(localized: "本地记录存储尚未接线")) }
        try onSaveRecord(withActivityCheckpoint(value))
    }

    func persist(_ id: UUID) {
        guard let value = records[id] else { return }
        do {
            try save(value)
            if pendingAudio[id]?.isEmpty != false, pendingFinalInputs[id]?.isEmpty != false { savingCallIDs.remove(id) }
        } catch { reportSavingFailure(error, callID: id) }
    }

    func reportSavingFailure(_ error: Error, callID: UUID) {
        savingCallIDs.insert(callID)
        if record?.id == callID { errorMessage = String(localized: "记录未保存，请重试：\(safeMessage(error))") }
    }
}
