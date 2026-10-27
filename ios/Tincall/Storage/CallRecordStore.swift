// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

@MainActor @Observable
final class CallRecordStore {
    private(set) var records: [CallRecord] = []
    private(set) var storageIssue: String?
    private(set) var unavailableRecordIDs: Set<UUID> = []
    private(set) var hasUnidentifiedUnavailableRecords = false
    @ObservationIgnored var canDeleteRecord: ((UUID) -> Bool)?
    @ObservationIgnored var onDeleteRecord: ((UUID) -> Void)?
    var finishedRecords: [CallRecord] { records.filter(\.isFinished) }
    private let directory: URL
    let mediaDirectory: URL
    private let fileManager = FileManager.default
    private let strictLoading: Bool

    struct StorageUsage: Sendable {
        var textBytes: Int64 = 0
        var imageBytes: Int64 = 0
        var audioBytes: Int64 = 0
    }

    struct BackupSnapshot: Sendable {
        let records: [CallRecord]
        let media: [UUID: [String: URL]]
    }

    /// Capture validated value data and source URLs on the actor. Callers may
    /// encode/copy these immutable values on a worker without touching the store.
    func backupSnapshot() throws -> BackupSnapshot {
        try requireCompleteLoading()
        var media: [UUID: [String: URL]] = [:]
        for record in records {
            try requireAvailableRecord(record.id)
            let audio = try record.audioAssets.map { ($0, try audioURL($0, recordID: record.id)) }
            let images = try record.messages.flatMap { message in
                try (message.images ?? []).map { ($0, try imageURL($0, recordID: record.id, messageID: message.id)) }
            }
            try checkMedia(audio.map { $0.1 } + images.map { $0.1 })
            var files: [String: URL] = [:]
            for (asset, url) in audio { files[archiveAudioName(asset)] = url }
            for (asset, url) in images { files["\(asset.id.uuidString).\(url.pathExtension)"] = url }
            media[record.id] = files
        }
        return BackupSnapshot(records: records, media: media)
    }

    enum LocalDataCategory: CaseIterable {
        case audio, images, records

        func contains(_ record: CallRecord) -> Bool {
            switch self {
            case .audio: !record.audioAssets.isEmpty
            case .images: record.messages.contains { $0.images?.isEmpty == false }
            case .records: true
            }
        }
    }

    func recordsForCleanup(_ category: LocalDataCategory) throws -> [CallRecord] {
        try requireCompleteLoading()
        let targets = records.filter(category.contains)
        for record in targets {
            guard record.isFinished else { throw TincallError(message: String(localized: "请结束通话后再清理本机数据。")) }
            try requireDeletable(record)
        }
        return targets
    }

    /// Each record commits its index before removing staged files. A failed save restores its media.
    func clearLocalData(_ category: LocalDataCategory) throws {
        let targets = try recordsForCleanup(category)
        for record in targets {
            if category == .records {
                try delete(recordID: record.id)
                continue
            }
            var updated = record
            let files: [URL]
            switch category {
            case .audio:
                files = try record.audioAssets.map { try audioURL($0, recordID: record.id) }
                updated.audioAssets = []
            case .images:
                files = try record.messages.flatMap { message in
                    try (message.images ?? []).map { try imageURL($0, recordID: record.id, messageID: message.id) }
                }
                for index in updated.messages.indices { updated.messages[index].images = nil }
            case .records: continue
            }
            let trash = directory.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
            var moved: [(original: URL, staged: URL)] = []
            do {
                for (index, file) in files.enumerated() where fileManager.fileExists(atPath: file.path) {
                    let staged = trash.appendingPathComponent(String(index))
                    try fileManager.moveItem(at: file, to: staged)
                    moved.append((file, staged))
                }
                try save(updated)
            } catch {
                let failure = error
                for file in moved.reversed() {
                    do { try fileManager.moveItem(at: file.staged, to: file.original) }
                    catch { throw TincallError(message: String(localized: "清理未完成，媒体文件已保留在本机恢复目录，请勿清理 App 数据。")) }
                }
                try fileManager.removeItem(at: trash)
                throw failure
            }
            // Forget the coordinator's old snapshot so a later summary/resume cannot restore removed indexes.
            onDeleteRecord?(record.id)
            do { try fileManager.removeItem(at: trash) }
            catch { throw TincallError(message: String(localized: "记录已更新，临时媒体清理失败，请检查本机存储空间。")) }
        }
    }

    /// Read file metadata only; media contents are not loaded to calculate usage.
    func storageUsage() throws -> StorageUsage {
        try requireCompleteLoading()
        var usage = StorageUsage()
        for record in records {
            usage.textBytes += Int64(try checkedFileSize(recordURL(record.id)))
            for message in record.messages {
                for image in message.images ?? [] {
                    usage.imageBytes += Int64(try checkedFileSize(imageURL(image, recordID: record.id, messageID: message.id)))
                }
            }
            for audio in record.audioAssets {
                usage.audioBytes += Int64(try checkedFileSize(audioURL(audio, recordID: record.id)))
            }
        }
        return usage
    }

    func checkAvailableSpace(requiredBytes: Int64) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
           requiredBytes > available {
            throw TincallError(message: String(localized: "本机剩余存储空间不足，无法导入完整备份。请释放空间后重试。"))
        }
    }

    private struct Archive: Codable {
        let version: Int
        var record: CallRecord
    }

    init(directory: URL? = nil, strictLoading: Bool = false) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Tincall/Records", isDirectory: true)
        self.directory = root
        self.strictLoading = strictLoading
        mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try reload()
    }

    func reload() throws {
        let urls: [URL]
        do { urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch {
            // A failed enumeration cannot establish which records are absent.
            hasUnidentifiedUnavailableRecords = true
            storageIssue = String(localized: "通话记录目录未能读取，原文件已保留。记录写入和云端同步已暂停，请稍后重试。")
            throw error
        }
        var loaded: [CallRecord] = []
        var unavailable: Set<UUID> = []
        var unidentified = false
        var failures = 0
        for url in urls where url.pathExtension.lowercased() == "json" {
            var decodedID: UUID?
            do {
                let record = try JSONDecoder().decode(CallRecord.self, from: Data(contentsOf: url))
                decodedID = record.id
                guard url.lastPathComponent == "\(record.id.uuidString).json" else { throw TincallError(message: String(localized: "通话记录标识不匹配")) }
                try validate(record)
                loaded.append(record)
            } catch {
                if strictLoading { throw error }
                // Permission, protected-data and newer-schema failures are unavailable,
                // not proof of corruption. Never rename, rewrite or remove the file.
                failures += 1
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                    unavailable.insert(id)
                    if let decodedID, decodedID != id { unidentified = true }
                } else { unidentified = true }
            }
        }
        unavailableRecordIDs = unavailable
        hasUnidentifiedUnavailableRecords = unidentified
        storageIssue = failures == 0 ? nil : String(localized: "有 \(failures) 个通话记录文件未能读取，原文件已保留。其他可读记录仍可查看；完整备份、导入和清理暂不可用。")
        if unidentified { storageIssue = (storageIssue ?? "") + String(localized: "存在无法确定归属的记录文件，记录写入和云端同步已暂停。") }
        records = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    func canModifyRecord(_ id: UUID) -> Bool {
        !hasUnidentifiedUnavailableRecords && !unavailableRecordIDs.contains(id)
    }

    func requireCompleteLoading() throws {
        if let storageIssue { throw TincallError(message: storageIssue) }
    }

    private func requireAvailableRecord(_ id: UUID) throws {
        guard canModifyRecord(id) else {
            throw TincallError(message: String(localized: "此记录的本机文件未能完整读取，原文件已保留。请先恢复本机文件后再修改或同步。"))
        }
    }

    func save(_ record: CallRecord) throws {
        try requireAvailableRecord(record.id)
        try validate(record)
        let data = try JSONEncoder().encode(record)
        try data.write(to: recordURL(record.id), options: .atomic)
        records.removeAll { $0.id == record.id }
        records.append(record)
        records.sort { $0.startedAt > $1.startedAt }
    }

    /// Run once at app launch, never during reload or staged import. The real end time is unknown.
    func recoverUnfinishedCalls() throws {
        // An unidentified file may belong to any call. Keep readable history visible
        // without rewriting a record while its ownership is uncertain.
        guard !hasUnidentifiedUnavailableRecords else { return }
        for var record in records where !record.isFinished {
            record.endedAbnormally = true
            if record.externalCallID == nil {
                for index in record.messages.indices where record.messages[index].status == .generating {
                    record.messages[index].status = .interrupted
                }
                record.queuedInputIDs = nil
            }
            if record.summaryStatus == .pending || record.summaryStatus == .generating {
                record.summaryStatus = .failed
            }
            try save(record)
        }
    }

    func delete(recordID: UUID) throws {
        try requireAvailableRecord(recordID)
        guard let record = records.first(where: { $0.id == recordID }) else { return }
        try requireDeletable(record)
        let manifest = recordURL(recordID)
        let media = mediaDirectory.appendingPathComponent(recordID.uuidString, isDirectory: true)
        let trash = directory.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let savedManifest = trash.appendingPathComponent("record.json")
        let savedMedia = trash.appendingPathComponent("media", isDirectory: true)
        do {
            try fileManager.moveItem(at: manifest, to: savedManifest)
            if fileManager.fileExists(atPath: media.path) { try fileManager.moveItem(at: media, to: savedMedia) }
        } catch {
            if fileManager.fileExists(atPath: savedManifest.path) {
                do { try fileManager.moveItem(at: savedManifest, to: manifest) }
                catch { throw TincallError(message: String(localized: "删除未完成，记录已保留在本机恢复目录，请勿清理 App 数据。")) }
            }
            throw error
        }
        records.removeAll { $0.id == recordID }
        onDeleteRecord?(recordID)
        do { try fileManager.removeItem(at: trash) }
        catch { throw TincallError(message: String(localized: "记录已移除，临时文件清理失败，请检查本机存储空间。")) }
    }

    private func requireDeletable(_ record: CallRecord) throws {
        let recordID = record.id
        try requireAvailableRecord(recordID)
        guard canDeleteRecord?(recordID) != false else { throw TincallError(message: String(localized: "通话仍在保存，请完成保存后再删除。")) }
        guard record.summaryStatus != .pending, record.summaryStatus != .generating,
              record.externalPendingControl == nil, record.externalPendingInput == nil,
              record.queuedInputIDs?.isEmpty != false else {
            throw TincallError(message: String(localized: "此通话仍有待完成的任务，请完成或结束任务后再删除。"))
        }
    }

    /// Save the current message first. Early audio must wait in the coordinator until then.
    /// Return only after durable copy AND atomic index save. Caller may then remove source.
    func saveAudio(recordID: UUID, segment: VoiceAudioSegment) throws -> CallAudioAsset {
        try requireAvailableRecord(recordID)
        guard var record = records.first(where: { $0.id == recordID }) else { throw TincallError(message: String(localized: "请先保存通话文字，再保存音频")) }
        guard segment.segmentIndex >= 0, record.messages.contains(where: { $0.id == segment.messageID }) else { throw TincallError(message: String(localized: "语音分段与通话消息不匹配")) }
        if let existing = record.audioAssets.first(where: { $0.id == segment.id }) {
            guard existing.messageID == segment.messageID, existing.segmentIndex == segment.segmentIndex,
                  fileManager.fileExists(atPath: try audioURL(existing, recordID: recordID).path) else { throw TincallError(message: String(localized: "已有音频分段不匹配或文件缺失")) }
            return existing
        }
        guard !record.audioAssets.contains(where: { $0.messageID == segment.messageID && $0.segmentIndex == segment.segmentIndex }) else { throw TincallError(message: String(localized: "此语音分段已经保存")) }
        let ext = segment.fileURL.pathExtension.lowercased()
        guard segment.fileURL.isFileURL, ["wav", "mp3", "m4a", "caf", "aac"].contains(ext) else { throw TincallError(message: String(localized: "不支持保存此音频格式")) }
        let relativePath = "\(record.id.uuidString)/\(segment.messageID.uuidString)/\(segment.segmentIndex)-\(UUID().uuidString).\(ext)"
        let asset = CallAudioAsset(id: segment.id, messageID: segment.messageID, segmentIndex: segment.segmentIndex, relativePath: relativePath, duration: segment.duration)
        let destination = try audioURL(asset, recordID: record.id)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: segment.fileURL, to: destination)
        record.audioAssets.append(asset)
        // An index write failure leaves the previous JSON and source audio intact.
        // The copied file remains durable for recovery rather than deleting captured audio.
        try save(record)
        return asset
    }

    /// Stage durable JPEGs before the coordinator atomically accepts the whole message.
    func saveImages(recordID: UUID, messageID: UUID, images: [Data]) throws -> [CallImageAsset] {
        try requireAvailableRecord(recordID)
        guard records.contains(where: { $0.id == recordID }), !images.isEmpty, images.count <= 4,
              images.allSatisfy({ !$0.isEmpty }) else { throw TincallError(message: String(localized: "无法保存消息图片")) }
        for data in images { try ConnectorMessageImage.validate(data, mimeType: "image/jpeg") }
        var saved: [URL] = []
        do {
            return try images.map { data in
                let id = UUID()
                let asset = CallImageAsset(id: id, relativePath: "\(recordID.uuidString)/\(messageID.uuidString)/\(id.uuidString).jpg")
                let url = try imageURL(asset, recordID: recordID, messageID: messageID)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                saved.append(url)
                return asset
            }
        } catch {
            for url in saved {
                do { try fileManager.removeItem(at: url) }
                catch { throw TincallError(message: String(localized: "消息图片清理失败，请检查本机存储空间")) }
            }
            throw error
        }
    }

    /// Install immutable downloaded media before publishing its record index.
    func installImage(_ data: Data, asset: CallImageAsset, recordID: UUID, messageID: UUID) throws {
        try requireAvailableRecord(recordID)
        try ConnectorMessageImage.validate(data, mimeType: asset.mimeType)
        let destination = try imageURL(asset, recordID: recordID, messageID: messageID)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw TincallError(message: String(localized: "已有消息图片内容不同，未覆盖")) }
            return
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func imageURL(_ asset: CallImageAsset, recordID: UUID, messageID: UUID) throws -> URL {
        let ext = URL(fileURLWithPath: asset.relativePath).pathExtension
        let expected = "\(recordID.uuidString)/\(messageID.uuidString)/\(asset.id.uuidString).\(ext)"
        guard ["jpg", "png"].contains(ext), asset.relativePath == expected else { throw TincallError(message: String(localized: "消息图片路径无效")) }
        let url = mediaDirectory.appendingPathComponent(expected)
        let root = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
            throw TincallError(message: String(localized: "消息图片路径无效"))
        }
        return url
    }

    func updateSummary(recordID: UUID, status: SummaryStatus, text: String? = nil) throws {
        guard var record = records.first(where: { $0.id == recordID }) else { throw TincallError(message: String(localized: "找不到通话记录")) }
        record.summaryStatus = status
        if let text {
            if record.summary != text { record.summaryUploadRequestID = UUID() }
            record.summary = text
        }
        try save(record)
    }

    /// A portable single-call backup, including only audio already selected for retention.
    func exportRecord(_ id: UUID) throws -> (manifest: Data, media: [String: URL]) {
        try requireAvailableRecord(id)
        guard let record = records.first(where: { $0.id == id }) else { throw TincallError(message: String(localized: "找不到通话记录")) }
        let sources = try record.audioAssets.map { ($0, try audioURL($0, recordID: id)) }
        let imageSources = try record.messages.flatMap { message in
            try (message.images ?? []).map { ($0, try imageURL($0, recordID: id, messageID: message.id)) }
        }
        try checkMedia(sources.map { $0.1 } + imageSources.map { $0.1 })
        let data = try JSONEncoder().encode(Archive(version: 1, record: record))
        var media: [String: URL] = [:]
        for (asset, url) in sources {
            media[archiveAudioName(asset)] = url
        }
        for (asset, url) in imageSources { media["\(asset.id.uuidString).\(url.pathExtension)"] = url }
        return (data, media)
    }

    struct ImportResult {
        let record: CallRecord
        let imported: Bool
    }

    /// Existing calls keep their local text, summary and audio. Never writes an archive-supplied path.
    @discardableResult
    func importRecord(from package: URL, asIndependentCopy: Bool = false) throws -> ImportResult {
        try requireCompleteLoading()
        guard package.isFileURL else { throw TincallError(message: String(localized: "请选择本地通话备份目录")) }
        let packageInfo = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageInfo.isDirectory == true, packageInfo.isSymbolicLink != true else { throw TincallError(message: String(localized: "请选择非符号链接的备份目录")) }
        let manifest = package.appendingPathComponent("record.json")
        let manifestSize = try checkedFileSize(manifest)
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: manifest)) }
        catch { throw TincallError(message: String(localized: "不是有效的 Tincall 通话备份")) }
        guard archive.version == 1 else { throw TincallError(message: String(localized: "不支持此备份版本")) }
        try validate(archive.record)
        let sourceDirectory = package.appendingPathComponent("media", isDirectory: true)
        let mediaInfo = try sourceDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard mediaInfo.isDirectory == true, mediaInfo.isSymbolicLink != true else { throw TincallError(message: String(localized: "备份媒体目录无效")) }
        let sources = try archive.record.audioAssets.map { asset -> URL in
            let ext = URL(fileURLWithPath: asset.relativePath).pathExtension.lowercased()
            guard ["wav", "mp3", "m4a", "caf", "aac"].contains(ext) else { throw TincallError(message: String(localized: "备份音频格式无效")) }
            return sourceDirectory.appendingPathComponent(archiveAudioName(asset))
        }
        let imageSources = archive.record.messages.flatMap { ($0.images ?? []).map { sourceDirectory.appendingPathComponent("\($0.id.uuidString).\(URL(fileURLWithPath: $0.relativePath).pathExtension)") } }
        let allSources = sources + imageSources
        let files = try fileManager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard Set(files.map(\.lastPathComponent)) == Set(allSources.map(\.lastPathComponent)), files.count == allSources.count else { throw TincallError(message: String(localized: "备份的音频与索引不完整")) }
        let mediaBytes = try checkMedia(allSources)
        if !asIndependentCopy, let existing = matchingRecord(archive.record, in: records) {
            return ImportResult(record: existing, imported: false)
        }
        try checkAvailableSpace(requiredBytes: Int64(manifestSize) + mediaBytes)
        var record = archive.record
        record.id = UUID()
        record.sourceRecordID = asIndependentCopy ? record.id : archive.record.sourceRecordID ?? archive.record.id
        // A backup is a new local record, never a live remote session or control outbox.
        record.externalCallID = nil
        record.externalEventCursor = nil
        record.externalEpoch = nil
        record.externalPendingInput = nil
        record.queuedInputIDs = nil
        record.externalPendingControl = nil
        record.externalReplyID = nil
        record.externalAnswerRequestID = nil
        if !record.isFinished { record.endedAbnormally = true }
        for index in record.messages.indices where record.messages[index].status == .generating {
            record.messages[index].status = .interrupted
        }
        if record.summaryStatus == .pending || record.summaryStatus == .generating {
            // An archive contains no running task. Preserve text and expose the retry action.
            record.summaryStatus = .failed
        }
        let newMedia = mediaDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        do {
            for index in record.audioAssets.indices {
                var asset = record.audioAssets[index]
                let ext = sources[index].pathExtension
                asset.relativePath = "\(record.id.uuidString)/\(asset.messageID.uuidString)/\(asset.segmentIndex)-\(UUID().uuidString).\(ext)"
                let destination = try audioURL(asset, recordID: record.id)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sources[index], to: destination)
                record.audioAssets[index] = asset
            }
            for index in record.messages.indices {
                guard let images = record.messages[index].images else { continue }
                let messageID = record.messages[index].id
                record.messages[index].images = try images.map { original in
                    var asset = original
                    let name = "\(asset.id.uuidString).\(URL(fileURLWithPath: original.relativePath).pathExtension)"
                    asset.relativePath = "\(record.id.uuidString)/\(messageID.uuidString)/\(name)"
                    let destination = try imageURL(asset, recordID: record.id, messageID: messageID)
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: sourceDirectory.appendingPathComponent(name), to: destination)
                    return asset
                }
            }
            try save(record)
            return ImportResult(record: record, imported: true)
        } catch {
            if fileManager.fileExists(atPath: newMedia.path) {
                do { try fileManager.removeItem(at: newMedia) }
                catch { throw TincallError(message: String(localized: "导入失败，新建媒体清理失败；原记录未改变。")) }
            }
            throw error
        }
    }

    /// Install only newly staged calls. Rollback never removes an existing call.
    @discardableResult
    func installImportedRecords(from staged: CallRecordStore, deduplicate: Bool = false) throws -> [CallRecord] {
        try requireCompleteLoading()
        try staged.requireCompleteLoading()
        var incoming: [CallRecord] = []
        for record in staged.records {
            if deduplicate, matchingRecord(record, in: records + incoming) != nil { continue }
            incoming.append(record)
        }
        guard incoming.allSatisfy({ record in
            !records.contains { $0.id == record.id }
                && !fileManager.fileExists(atPath: recordURL(record.id).path)
                && !fileManager.fileExists(atPath: mediaDirectory.appendingPathComponent(record.id.uuidString).path)
        }) else { throw TincallError(message: String(localized: "新导入记录标识冲突，原记录未改变")) }
        var installedJSON: [URL] = []
        var installedMedia: [URL] = []
        do {
            for record in incoming {
                try validate(record)
                if !record.audioAssets.isEmpty || record.messages.contains(where: { $0.images?.isEmpty == false }) {
                    let source = staged.mediaDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
                    let destination = mediaDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
                    try fileManager.moveItem(at: source, to: destination)
                    installedMedia.append(destination)
                }
                let destination = recordURL(record.id)
                try JSONEncoder().encode(record).write(to: destination, options: .atomic)
                installedJSON.append(destination)
            }
        } catch {
            do {
                for url in installedJSON { try fileManager.removeItem(at: url) }
                for url in installedMedia { try fileManager.removeItem(at: url) }
            } catch { throw TincallError(message: String(localized: "导入未完成，新记录清理失败；原有数据保留。")) }
            throw error
        }
        records.append(contentsOf: incoming)
        records.sort { $0.startedAt > $1.startedAt }
        return incoming
    }

    private enum And {
        static let word = "and"
    }

    private func matchingRecord(_ incoming: CallRecord, in candidates: [CallRecord]) -> CallRecord? {
        let sourceID = incoming.sourceRecordID ?? incoming.id
        if let existing = candidates.first(where: { ($0.sourceRecordID ?? $0.id) == sourceID || $0.id == incoming.id }) { return existing }
        // Old imports discarded the call UUID but retained message UUIDs. Never match on time or text alone.
        guard let firstMessageID = incoming.messages.first?.id else { return nil }
        return candidates.first {
            $0.sourceRecordID == nil && $0.startedAt == incoming.startedAt && $0.messages.first?.id == firstMessageID
        }
    }

    /// Undo the newly installed batch if configuration commit fails.
    func rollbackImportedRecords(_ incoming: [CallRecord]) throws {
        for record in incoming { try requireAvailableRecord(record.id) }
        for record in incoming {
            try fileManager.removeItem(at: recordURL(record.id))
            records.removeAll { $0.id == record.id }
            let media = mediaDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: media.path) { try fileManager.removeItem(at: media) }
        }
    }

    private func archiveAudioName(_ asset: CallAudioAsset) -> String {
        "\(asset.id.uuidString).\(URL(fileURLWithPath: asset.relativePath).pathExtension.lowercased())"
    }

    private func checkedFileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw TincallError(message: String(localized: "备份文件缺失、为空或包含符号链接")) }
        return size
    }

    @discardableResult
    private func checkMedia(_ urls: [URL]) throws -> Int64 {
        var total: Int64 = 0
        for url in urls {
            total += Int64(try checkedFileSize(url))
        }
        return total
    }

    func audioURL(_ asset: CallAudioAsset, recordID: UUID) throws -> URL {
        let parts = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Substring(recordID.uuidString), parts[1] == Substring(asset.messageID.uuidString),
              !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              !asset.relativePath.contains("\\"), parts[2].hasPrefix("\(asset.segmentIndex)-") else {
            throw TincallError(message: String(localized: "音频索引路径无效"))
        }
        let url = mediaDirectory.appendingPathComponent(asset.relativePath)
        let rootPath = mediaDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath) else { throw TincallError(message: String(localized: "音频索引超出记录目录")) }
        return url
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func validate(_ record: CallRecord) throws {
        guard Set(record.messages.map(\.id)).count == record.messages.count,
              Set(record.audioAssets.map(\.id)).count == record.audioAssets.count,
              record.endedAt.map({ $0 >= record.startedAt }) ?? true,
              record.lastActiveAt.map({ $0 >= record.startedAt }) ?? true,
              record.recordedActiveDuration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw TincallError(message: String(localized: "通话记录格式无效")) }
        var segmentKeys = Set<String>()
        var imageIDs = Set<UUID>()
        for message in record.messages {
            guard (message.images?.count ?? 0) <= 4 else { throw TincallError(message: String(localized: "一次最多发送 4 张图片")) }
            for image in message.images ?? [] {
                guard imageIDs.insert(image.id).inserted else { throw TincallError(message: String(localized: "消息图片路径无效")) }
                _ = try imageURL(image, recordID: record.id, messageID: message.id)
            }
        }
        for asset in record.audioAssets {
            guard asset.segmentIndex >= 0, record.messages.contains(where: { $0.id == asset.messageID }),
                  segmentKeys.insert("\(asset.messageID.uuidString):\(asset.segmentIndex)").inserted,
                  asset.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw TincallError(message: String(localized: "语音分段索引无效")) }
            _ = try audioURL(asset, recordID: record.id)
        }
    }
}
