// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

// Standalone Store regression checks. All fixtures below are test-only; no real transport or Keychain is used.
// From the repository root:
// xcrun swiftc -swift-version 6 -parse-as-library ios/Tincall/Core/CallModels.swift ios/Tincall/Storage/CallRecordStore.swift ios/Tincall/Storage/CloudSyncModels.swift ios/Tincall/Storage/CloudSyncStore.swift ios/Tincall/Storage/CloudRecordTransfer.swift ios/Tests/AutomaticCloudSyncStoreChecks.swift -o /tmp/tincall-auto-sync-store-checks
// /tmp/tincall-auto-sync-store-checks
import Foundation

struct CredentialStore { }
struct CloudSyncFailure: LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? { code }
}
@MainActor final class ExternalCallClient {
    func uploadSummary(for record: CallRecord, connection: ConnectionProfile) async { }
}
@MainActor enum Fixture {
    static var owner = UUID()
    static var rows: [UUID: CloudSyncRemote] = [:]
    static var replies: [UUID: CloudSyncRemote] = [:]
    static var requests: [UUID] = []
    static var mutations: [CloudSyncPending] = []
    static var backupOnlyDeletion = true
    static var ownerReads = 0
    static var recordReads: [UUID] = []
    static var uploadCount = 0
    static var downloadCount = 0
    static var failAfterCommit = false
    static var delayGet = false
    static var enteredGet = false
    static var onUpload: (() throws -> Void)?
    static var onDownload: (() throws -> Void)?
    static var onImageDownload: (() throws -> Void)?
    static let imageBytes = Data([0xff, 0xd8, 0xff, 0x20])
    static func reset() {
        rows = [:]; replies = [:]; requests = []; mutations = []; backupOnlyDeletion = true; ownerReads = 0; recordReads = []
        uploadCount = 0; downloadCount = 0; failAfterCommit = false
        delayGet = false; enteredGet = false; onUpload = nil; onDownload = nil; onImageDownload = nil
    }
}
@MainActor final class CloudSyncClient {
    static let maximumMediaBytes = 512 * 1024 * 1024
    var isAutomaticSync = false
    var supportsBackupOnlyDeletion: Bool { Fixture.backupOnlyDeletion }
    init(credentials: CredentialStore) { }
    func owner(connection: ConnectionProfile) async throws -> UUID { Fixture.ownerReads += 1; return Fixture.owner }
    func list(connection: ConnectionProfile) async throws -> [CloudSyncRemote] {
        Fixture.rows.values.map { row in var index = row; index.record = nil; return index }
    }
    func get(connection: ConnectionProfile, id: UUID) async throws -> CloudSyncRemote? {
        Fixture.recordReads.append(id)
        Fixture.enteredGet = true
        if Fixture.delayGet { try? await Task.sleep(for: .milliseconds(300)) }
        return Fixture.rows[id]
    }
    func mutate(connection: ConnectionProfile, pending: CloudSyncPending, images: [UUID: ConnectorMessageImage]) async throws -> CloudSyncRemote {
        Fixture.requests.append(pending.requestID)
        Fixture.mutations.append(pending)
        if let previous = Fixture.replies[pending.requestID] { return previous }
        guard (Fixture.rows[pending.recordID]?.revision ?? 0) == pending.expectedRevision else { throw CloudSyncFailure(status: 409, code: "revision_conflict") }
        var document = pending.document
        if let d = document {
            document?.imageReferences = d.call.messages.flatMap { ($0.images ?? []).map { asset in
                CloudSyncImageReference(id: asset.id, mime_type: asset.mimeType, bytes: Fixture.imageBytes.count)
            }}
        }
        let result = CloudSyncRemote(id: pending.recordID, revision: pending.expectedRevision + 1, deleted: pending.isDelete, updated_at: "2026-10-19", record: document)
        Fixture.rows[result.id] = result; Fixture.replies[pending.requestID] = result
        if Fixture.failAfterCommit { Fixture.failAfterCommit = false; throw URLError(.networkConnectionLost) }
        return result
    }
    func upload(connection: ConnectionProfile, recordID: UUID, media: CloudSyncMedia, file: URL) async throws { Fixture.uploadCount += 1; try Fixture.onUpload?() }
    func download(connection: ConnectionProfile, recordID: UUID, media: CloudSyncMedia, destination: URL) async throws {
        Fixture.downloadCount += 1
        try Fixture.onDownload?()
        try Data(repeating: 0x20, count: media.bytes).write(to: destination)
    }
    func downloadImage(connection: ConnectionProfile, recordID: UUID, image: CloudSyncImageReference, destination: URL) async throws { try Fixture.onImageDownload?(); try Fixture.imageBytes.write(to: destination) }
    func callImageIDs(connection: ConnectionProfile, callID: UUID) async throws -> [UUID] { [] }
    func removeMedia(connection: ConnectionProfile, recordID: UUID, objectID: UUID) async throws { }
}

@main struct AutomaticCloudSyncStoreChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TincallAutomaticChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var pass = 0
        func check(_ condition: @autoclosure () -> Bool, _ title: String) {
            guard condition() else { fatalError("FAIL: \(title)") }
            pass += 1; print("PASS: \(title)")
        }
        func make(_ name: String) throws -> (CallRecordStore, CloudSyncStore, URL) {
            let directory = root.appendingPathComponent(name)
            let records = try CallRecordStore(directory: directory.appendingPathComponent("records"))
            let state = directory.appendingPathComponent("sync")
            let sync = try CloudSyncStore(records: records, directory: state)
            return (records, sync, state)
        }
        func record(_ text: String) -> CallRecord {
            CallRecord(roleID: UUID(), roleName: "Synthetic", startedAt: Date(timeIntervalSinceNow: -10), endedAt: Date(), messages: [CallMessage(turnID: UUID(), role: .assistant, text: text)], summaryStatus: .completed, summary: "Synthetic summary")
        }
        let connection = ConnectionProfile(name: "Isolated fixture", provider: .genericConnector, endpoint: URL(string: "https://fixture.invalid"))
        do {
            Fixture.reset()
            let (records, sync, directory) = try make("unreadable-local")
            let local = record("Preserve unreadable local and cloud copies")
            try records.save(local)
            try sync.select(connection.id)
            try sync.setAutomaticSyncEnabled(true)
            await sync.synchronizeAutomatically(connection: connection)
            check(Fixture.rows[local.id] != nil, "fixture establishes an existing cloud checkpoint")
            let before = try Data(contentsOf: directory.appendingPathComponent("state.json"))
            let manifest = directory.deletingLastPathComponent().appendingPathComponent("records/\(local.id.uuidString).json")
            let unavailableBytes = Data("{synthetic unreadable local record".utf8)
            try unavailableBytes.write(to: manifest)
            try records.reload()
            let reads = Fixture.ownerReads
            let writes = Fixture.mutations.count
            check(!sync.canSynchronizeRecord(local.id), "unreadable local IDs cannot be synchronized as missing records")
            await sync.synchronizeAutomatically(connection: connection)
            await sync.synchronize(connection: connection)
            await sync.restore(connection: connection, id: local.id)
            await sync.useLocal(connection: connection, id: local.id)
            await sync.deleteRemote(connection: connection, id: local.id)
            await sync.continuePending(connection: connection)
            check(sync.errorMessage != nil && Fixture.ownerReads == reads && Fixture.mutations.count == writes, "unreadable records block automatic sync, conflict choices and cloud mutations before transport")
            let after = try Data(contentsOf: directory.appendingPathComponent("state.json"))
            let retained = try Data(contentsOf: manifest)
            check(before == after && retained == unavailableBytes, "unreadable records neither set localRemoved checkpoints nor overwrite originals")
            try JSONEncoder().encode(local).write(to: manifest)
            try records.reload()
            await sync.synchronize(connection: connection)
            check(sync.errorMessage == nil && Fixture.mutations.count == writes, "manual sync resumes after files are readable without rewriting cloud history")
            let unknown = manifest.deletingLastPathComponent().appendingPathComponent("unknown.json")
            try unavailableBytes.write(to: unknown)
            try records.reload()
            check(!sync.canSynchronizeRecord(UUID()), "unidentified unreadable files block every record ID")
            let readsBeforeUnknown = Fixture.ownerReads
            await sync.synchronize(connection: connection)
            check(sync.errorMessage != nil && Fixture.ownerReads == readsBeforeUnknown, "uncertain record ownership pauses sync without inferring deletion")
            if CommandLine.arguments.contains("--unreadable-only") { return }
        }
        do {
            Fixture.reset()
            let (records, sync, directory) = try make("destination-change")
            let originalOwner = Fixture.owner
            let initial = record("Synthetic destination guard")
            try records.save(initial)
            try sync.select(connection.id); try sync.setAutomaticSyncEnabled(true)
            await sync.synchronizeAutomatically(connection: connection)
            var changed = connection
            changed.endpoint = URL(string: "https://different-fixture.invalid")
            try records.save(record("Never upload before target confirmation"))
            Fixture.mutations = []; Fixture.uploadCount = 0
            for _ in 0..<2 { await sync.synchronize(connection: changed) }
            check(Fixture.mutations.isEmpty && Fixture.uploadCount == 0, "changing the endpoint blocks repeated attempts")
            let reopened = try CloudSyncStore(records: records, directory: directory)
            await reopened.synchronizeAutomatically(connection: changed)
            check(Fixture.mutations.isEmpty, "unapproved endpoint stays blocked after restart")
            let needsConfirmation = await reopened.refresh(connection: changed)
            check(Fixture.mutations.isEmpty && needsConfirmation, "a view opening or ordinary refresh requests confirmation without approving a changed destination")
            await reopened.refresh(connection: changed, confirmDestinationChange: true)
            let unchangedNeedsConfirmation = await reopened.refresh(connection: changed)
            check(!unchangedNeedsConfirmation, "an unchanged destination refresh does not request repeated confirmation")
            await reopened.synchronizeAutomatically(connection: changed)
            check(!Fixture.mutations.isEmpty, "explicit refresh authorizes the new destination")
            Fixture.mutations = []; Fixture.owner = UUID()
            for _ in 0..<2 { await reopened.synchronize(connection: changed) }
            check(Fixture.mutations.isEmpty, "changing only the owner also stays blocked")
            Fixture.owner = originalOwner
            await reopened.refresh(connection: connection, confirmDestinationChange: true)
            let returned = try CloudSyncStore(records: records, directory: directory)
            await returned.synchronizeAutomatically(connection: connection)
            check(returned.errorMessage == nil, "the last confirmed destination persists when returning to an earlier ledger")
        }
        do {
            Fixture.reset()
            let (records, sync, directory) = try make("local-cleanup")
            var local = record("Keep synthetic cleanup text")
            try records.save(local)
            local.messages[0].images = try records.saveImages(recordID: local.id, messageID: local.messages[0].id, images: [Fixture.imageBytes])
            try records.save(local)
            try sync.select(connection.id); try sync.setAutomaticSyncEnabled(true)
            await sync.synchronizeAutomatically(connection: connection)
            check(sync.errorMessage == nil && Fixture.rows[local.id]?.record?.imageReferences?.count == 1, "cleanup fixture backs up an image through the production sync Store")
            try sync.prepareLocalDataRemoval(recordIDs: [local.id], category: .images)
            try records.clearLocalData(.images)
            let reopened = try CloudSyncStore(records: records, directory: directory)
            await reopened.synchronizeAutomatically(connection: connection)
            check(reopened.conflicts.contains(local.id) && Fixture.mutations.count == 1 && Fixture.rows[local.id]?.record?.imageReferences?.count == 1, "image cleanup remains an explicit conflict after restart, without deleting cloud images")
            check(records.records[0].messages[0].images == nil && records.records[0].messages[0].text == local.messages[0].text, "automatic sync does not silently restore locally cleared images")
            try reopened.prepareLocalDataRemoval(recordIDs: [local.id], category: .records)
            try records.clearLocalData(.records)
            await reopened.synchronizeAutomatically(connection: connection)
            check(records.records.isEmpty && Fixture.rows[local.id]?.deleted == false && Fixture.mutations.count == 1, "clearing local records neither restores them nor deletes cloud copies")

            var newLocal = record("Synthetic call not previously backed up")
            try records.save(newLocal)
            newLocal.messages[0].images = try records.saveImages(recordID: newLocal.id, messageID: newLocal.messages[0].id, images: [Fixture.imageBytes])
            try records.save(newLocal)
            try reopened.prepareLocalDataRemoval(recordIDs: [newLocal.id], category: .images)
            try records.clearLocalData(.images)
            await reopened.synchronizeAutomatically(connection: connection)
            check(Fixture.rows[newLocal.id]?.record?.call.messages[0].text == newLocal.messages[0].text && Fixture.rows[newLocal.id]?.record?.call.messages[0].images == nil, "image cleanup keeps never-backed-up calls eligible for their first upload")

            let audioFile = root.appendingPathComponent("cleanup.wav")
            try Data(repeating: 0x20, count: 32).write(to: audioFile)
            _ = try records.saveAudio(recordID: newLocal.id, segment: VoiceAudioSegment(id: UUID(), messageID: newLocal.messages[0].id, segmentIndex: 0, fileURL: audioFile, duration: 1))
            try reopened.setMediaEnabled(true)
            await reopened.synchronizeAutomatically(connection: connection)
            let writesBeforeCleanup = Fixture.mutations.count
            try reopened.prepareLocalDataRemoval(recordIDs: [newLocal.id], category: .audio)
            try records.clearLocalData(.audio)
            let audioReopened = try CloudSyncStore(records: records, directory: directory)
            await audioReopened.synchronizeAutomatically(connection: connection)
            check(audioReopened.errorMessage == nil && !audioReopened.conflicts.contains(newLocal.id) && records.records[0].audioAssets.isEmpty && Fixture.rows[newLocal.id]?.record?.media.count == 1 && Fixture.mutations.count == writesBeforeCleanup && Fixture.downloadCount == 0, "recording cleanup persists across restart, preserves cloud audio, and prevents automatic re-download without a text conflict")
            await audioReopened.restore(connection: connection, id: newLocal.id, includeMedia: true)
            check(audioReopened.errorMessage == nil && records.records[0].audioAssets.count == 1 && Fixture.downloadCount == 1, "explicitly restoring cloud recordings still works after local cleanup")

            // A committed write with a lost response still owns the local media until its journal is resolved.
            Fixture.reset()
            let (pendingRecords, pendingSync, _) = try make("cleanup-pending")
            let pending = record("Synthetic pending backup")
            try pendingRecords.save(pending)
            try pendingSync.select(connection.id); try pendingSync.setAutomaticSyncEnabled(true)
            Fixture.failAfterCommit = true
            await pendingSync.synchronizeAutomatically(connection: connection)
            do {
                try pendingSync.prepareLocalDataRemoval(recordIDs: [pending.id], category: .records)
                preconditionFailure("Unconfirmed cloud operations must block local cleanup")
            } catch is TincallError { }
            check(pendingRecords.records.count == 1 && pendingSync.hasPendingOperation, "pending cloud journal blocks cleanup before local data changes")
            if CommandLine.arguments.contains("--local-cleanup-only") { return }
        }
        do {
            Fixture.reset()
            let (records, sync, directory) = try make("unchanged-reopen")
            for _ in 0..<91 { try records.save(record("Synthetic unchanged call")) }
            try sync.select(connection.id); try sync.setAutomaticSyncEnabled(true)
            await sync.synchronizeAutomatically(connection: connection)
            check(sync.errorMessage == nil && Fixture.rows.count == 91, "initial sync establishes 91 checkpoints")
            Fixture.recordReads = []
            let reopened = try CloudSyncStore(records: records, directory: directory)
            await reopened.synchronizeAutomatically(connection: connection)
            print("Unchanged reopen: \(Fixture.recordReads.count) full-record downloads for 91 unchanged calls")
            check(reopened.errorMessage == nil && Fixture.recordReads.isEmpty, "reopening should download 0 unchanged conversations; actually downloaded \(Fixture.recordReads.count)")
            check(Fixture.mutations.count == 91, "unchanged reopen does not re-upload records")

            var localEdit = records.records[0]
            localEdit.messages[0].text = "Local edit"
            try records.save(localEdit)
            let remoteID = records.records.first { $0.id != localEdit.id }!.id
            var remote = Fixture.rows[remoteID]!
            remote.record!.call.messages[0].text = "Remote edit"
            Fixture.rows[remoteID] = CloudSyncRemote(id: remoteID, revision: 2, deleted: false, updated_at: "2026-10-21", record: remote.record)
            Fixture.recordReads = []
            await reopened.synchronizeAutomatically(connection: connection)
            check(reopened.errorMessage == nil && Set(Fixture.recordReads) == [localEdit.id, remoteID] && Fixture.recordReads.count == 2, "only the two changed records fetch full documents")
            check(Fixture.rows[localEdit.id]?.record?.call.messages[0].text == "Local edit" && records.records.first { $0.id == remoteID }?.messages[0].text == "Remote edit", "local and remote changes still synchronize in both directions")

            Fixture.rows[remoteID] = CloudSyncRemote(id: remoteID, revision: 3, deleted: true, updated_at: "2026-10-21", record: nil)
            await reopened.synchronizeAutomatically(connection: connection)
            Fixture.recordReads = []
            await reopened.synchronizeAutomatically(connection: connection)
            check(reopened.errorMessage == nil && Fixture.recordReads.isEmpty && Fixture.rows[remoteID]?.deleted == true, "unchanged deletion markers do not download again or resurrect cloud backups")
            if CommandLine.arguments.contains("--unchanged-only") { return }
        }
        Fixture.reset()
        let (oldRecords, _, oldDir) = try make("migration")
        let oldJSON: [String: Any] = ["selectedConnectionID": connection.id.uuidString, "textSyncEnabled": true, "ledgers": []]
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: oldDir.appendingPathComponent("state.json"))
        let old = try CloudSyncStore(records: oldRecords, directory: oldDir)
        check(old.textSyncEnabled && !old.automaticSyncEnabled, "legacy manual permission does not enable automatic sync")
        await old.synchronizeAutomatically(connection: connection)
        check(Fixture.ownerReads == 0, "disabled automatic sync performs no transport work")
        try old.setAutomaticSyncEnabled(true)
        let reloaded = try CloudSyncStore(records: oldRecords, directory: oldDir)
        check(reloaded.automaticSyncEnabled && reloaded.textSyncEnabled, "automatic consent persists and enables existing text path")
        try reloaded.setAutomaticSyncEnabled(false)
        check(!reloaded.automaticSyncEnabled && reloaded.textSyncEnabled, "disabling automatic sync preserves manual sync")

        Fixture.reset()
        let (abnormalRecords, abnormalSync, _) = try make("abnormal-ended")
        var abnormal = record("Interrupted call")
        abnormal.endedAt = nil
        abnormal.endedAbnormally = true
        try abnormalRecords.save(abnormal)
        try abnormalSync.select(connection.id); try abnormalSync.setAutomaticSyncEnabled(true)
        await abnormalSync.synchronizeAutomatically(connection: connection)
        check(Fixture.rows[abnormal.id]?.record?.call.endedAbnormally == true, "abnormally ended call uploads without a fabricated end time")
        let abnormalDocument = try CloudSyncDocument(call: abnormal).validated(recordID: abnormal.id)
        check(abnormalDocument.call.endedAt == nil, "cloud validation preserves unknown abnormal end time")
        let (restoredAbnormal, restoredAbnormalSync, _) = try make("abnormal-restore")
        try restoredAbnormalSync.select(connection.id); try restoredAbnormalSync.setAutomaticSyncEnabled(true)
        await restoredAbnormalSync.synchronizeAutomatically(connection: connection)
        check(restoredAbnormal.records.first?.endedAbnormally == true && restoredAbnormal.records.first?.endedAt == nil, "abnormally ended call restores to another device")
        let abnormalAudio = root.appendingPathComponent("abnormal.wav")
        try Data(repeating: 0x20, count: 32).write(to: abnormalAudio)
        _ = try abnormalRecords.saveAudio(recordID: abnormal.id, segment: VoiceAudioSegment(id: UUID(), messageID: abnormal.messages[0].id, segmentIndex: 0, fileURL: abnormalAudio, duration: 1))
        try abnormalSync.setMediaEnabled(true)
        await abnormalSync.synchronizeAutomatically(connection: connection)
        check(Fixture.uploadCount == 1 && Fixture.rows[abnormal.id]?.record?.media.count == 1, "consented saved audio also uploads for an abnormally ended call")
        var active = abnormal
        active.id = UUID(); active.endedAbnormally = nil
        try abnormalRecords.save(active)
        check(!abnormalSync.canSynchronizeRecord(active.id), "unfinished call remains blocked from synchronization")
        do {
            _ = try CloudSyncDocument(call: active).validated(recordID: active.id)
            fatalError("FAIL: unfinished cloud call must be rejected")
        } catch { }
        abnormalRecords.canDeleteRecord = { _ in false }
        check(!abnormalSync.canSynchronizeRecord(abnormal.id), "active coordinator work still blocks an ended record")

        Fixture.reset()
        let (records, sync, _) = try make("bidirectional")
        var local = record("Local upload")
        try records.save(local)
        local.messages[0].images = try records.saveImages(recordID: local.id, messageID: local.messages[0].id, images: [Fixture.imageBytes])
        try records.save(local)
        let remoteCall = record("Cloud download")
        Fixture.rows[remoteCall.id] = CloudSyncRemote(id: remoteCall.id, revision: 1, deleted: false, updated_at: "2026-10-19", record: CloudSyncDocument(call: remoteCall))
        try sync.select(connection.id); try sync.setAutomaticSyncEnabled(true)
        await sync.synchronizeAutomatically(connection: connection)
        check(sync.errorMessage == nil, "automatic bidirectional content sync completes")
        check(Fixture.rows[local.id]?.record?.call.summary == "Synthetic summary", "local summary uploads with text")
        check(Fixture.rows[local.id]?.record?.imageReferences?.count == 1, "local message images upload with stable references")
        check(records.records.contains { $0.id == remoteCall.id }, "cloud-only call restores to local records")
        let imageDocument = Fixture.rows[local.id]!.record!
        let (imageRecords, imageSync, _) = try make("image-download")
        Fixture.rows = [local.id: Fixture.rows[local.id]!]
        try imageSync.select(connection.id); try imageSync.setAutomaticSyncEnabled(true)
        await imageSync.synchronizeAutomatically(connection: connection)
        let downloadedImage = imageRecords.records.first { $0.id == local.id }?.messages[0].images?.first
        check(imageSync.errorMessage == nil && downloadedImage != nil && (try? imageRecords.imageURL(downloadedImage!, recordID: local.id, messageID: local.messages[0].id)) != nil, "cloud message images download before their record is installed")

        Fixture.reset()
        let (stoppedImages, stoppedImageSync, _) = try make("image-stop")
        Fixture.rows[local.id] = CloudSyncRemote(id: local.id, revision: 1, deleted: false, updated_at: "2026-10-19", record: imageDocument)
        try stoppedImageSync.select(connection.id); try stoppedImageSync.setAutomaticSyncEnabled(true)
        Fixture.onImageDownload = { try stoppedImageSync.setAutomaticSyncEnabled(false) }
        await stoppedImageSync.synchronizeAutomatically(connection: connection)
        check(stoppedImages.records.isEmpty && !stoppedImageSync.isBusy, "turning automatic sync off during image download prevents local record publication")

        Fixture.reset()
        let (audioRecords, audioSync, _) = try make("audio")
        let audioLocal = record("Local audio")
        try audioRecords.save(audioLocal)
        let audioFile = root.appendingPathComponent("synthetic.wav")
        try Data(repeating: 0x20, count: 32).write(to: audioFile)
        _ = try audioRecords.saveAudio(recordID: audioLocal.id, segment: VoiceAudioSegment(id: UUID(), messageID: audioLocal.messages[0].id, segmentIndex: 0, fileURL: audioFile, duration: 1))
        let audioRemote = record("Remote audio")
        let remoteAsset = CallAudioAsset(messageID: audioRemote.messages[0].id, segmentIndex: 0, relativePath: "remote.wav", duration: 1)
        Fixture.rows[audioRemote.id] = CloudSyncRemote(id: audioRemote.id, revision: 1, deleted: false, updated_at: "2026-10-19", record: CloudSyncDocument(call: audioRemote, media: [CloudSyncMedia(object_id: UUID(), asset: remoteAsset, bytes: 32)]))
        try audioSync.select(connection.id); try audioSync.setAutomaticSyncEnabled(true)
        await audioSync.synchronizeAutomatically(connection: connection)
        check(audioSync.errorMessage == nil && Fixture.uploadCount == 0 && Fixture.downloadCount == 0, "audio consent defaults off for both upload and download")
        try audioSync.setMediaEnabled(true)
        await audioSync.synchronizeAutomatically(connection: connection)
        check(audioSync.errorMessage == nil && Fixture.uploadCount == 1 && Fixture.downloadCount == 1, "consented audio uploads and missing cloud audio downloads")
        check(audioRecords.records.first { $0.id == audioRemote.id }?.audioAssets.first?.id == remoteAsset.id, "downloaded audio saves using original stable identity")
        await audioSync.synchronizeAutomatically(connection: connection)
        check(audioSync.errorMessage == nil && Fixture.uploadCount == 1 && Fixture.downloadCount == 1, "unchanged audio metadata avoids duplicate transfers after local path changes")
        try audioSync.setMediaEnabled(false)
        let newAudio = CallAudioAsset(messageID: audioRemote.messages[0].id, segmentIndex: 1, relativePath: "another.wav", duration: 1)
        var audioDoc = Fixture.rows[audioRemote.id]!.record!
        audioDoc.media.append(CloudSyncMedia(object_id: UUID(), asset: newAudio, bytes: 32))
        Fixture.rows[audioRemote.id] = CloudSyncRemote(id: audioRemote.id, revision: 2, deleted: false, updated_at: "2026-10-19", record: audioDoc)
        await audioSync.synchronizeAutomatically(connection: connection)
        check(Fixture.downloadCount == 1, "revoking audio consent stops subsequent automatic downloads")

        Fixture.reset()
        let (revokedRecords, revokedSync, _) = try make("revoke-upload")
        let revokedRecord = record("Audio permission revoked during upload")
        try revokedRecords.save(revokedRecord)
        _ = try revokedRecords.saveAudio(recordID: revokedRecord.id, segment: VoiceAudioSegment(id: UUID(), messageID: revokedRecord.messages[0].id, segmentIndex: 0, fileURL: audioFile, duration: 1))
        try revokedSync.select(connection.id); try revokedSync.setAutomaticSyncEnabled(true)
        await revokedSync.synchronizeAutomatically(connection: connection)
        try revokedSync.setMediaEnabled(true)
        let beforeRequests = Fixture.requests.count
        Fixture.onUpload = { try revokedSync.setMediaEnabled(false) }
        await revokedSync.synchronizeAutomatically(connection: connection)
        check(Fixture.requests.count == beforeRequests && revokedSync.hasPendingOperation && !revokedSync.mediaEnabled, "revoking consent during upload prevents publishing new audio manifest")

        Fixture.reset()
        let (downloadRecords, downloadSync, _) = try make("revoke-download")
        let downloadRecord = record("Audio permission revoked during download")
        let downloadAsset = CallAudioAsset(messageID: downloadRecord.messages[0].id, segmentIndex: 0, relativePath: "cloud.wav", duration: 1)
        Fixture.rows[downloadRecord.id] = CloudSyncRemote(id: downloadRecord.id, revision: 1, deleted: false, updated_at: "2026-10-19", record: CloudSyncDocument(call: downloadRecord, media: [CloudSyncMedia(object_id: UUID(), asset: downloadAsset, bytes: 32)]))
        try downloadSync.select(connection.id); try downloadSync.setAutomaticSyncEnabled(true)
        await downloadSync.refresh(connection: connection); try downloadSync.setMediaEnabled(true)
        Fixture.onDownload = { try downloadSync.setMediaEnabled(false) }
        await downloadSync.synchronizeAutomatically(connection: connection)
        check(downloadRecords.records.first?.audioAssets.isEmpty == true && !downloadSync.mediaEnabled, "revoking consent during download prevents installing downloaded audio")

        Fixture.reset()
        let (metadataRecords, metadataSync, _) = try make("metadata-conflict")
        let metadataRecord = record("Different audio metadata")
        try metadataRecords.save(metadataRecord)
        let retainedAsset = try metadataRecords.saveAudio(recordID: metadataRecord.id, segment: VoiceAudioSegment(id: UUID(), messageID: metadataRecord.messages[0].id, segmentIndex: 0, fileURL: audioFile, duration: 1))
        try metadataSync.select(connection.id); try metadataSync.setAutomaticSyncEnabled(true)
        await metadataSync.synchronizeAutomatically(connection: connection); try metadataSync.setMediaEnabled(true)
        var changedAsset = retainedAsset; changedAsset.duration = 2
        Fixture.rows[metadataRecord.id] = CloudSyncRemote(id: metadataRecord.id, revision: 2, deleted: false, updated_at: "2026-10-19", record: CloudSyncDocument(call: metadataRecord, media: [CloudSyncMedia(object_id: UUID(), asset: changedAsset, bytes: 32)]))
        await metadataSync.synchronizeAutomatically(connection: connection)
        check(metadataSync.conflicts.contains(metadataRecord.id) && metadataSync.errorMessage != nil && Fixture.uploadCount == 0 && Fixture.downloadCount == 0, "different audio metadata remains a visible conflict without replacing local files")

        Fixture.reset()
        let (conflictRecords, conflictSync, _) = try make("conflict")
        var both = record("Base")
        try conflictRecords.save(both); try conflictSync.select(connection.id); try conflictSync.setAutomaticSyncEnabled(true)
        await conflictSync.synchronizeAutomatically(connection: connection)
        both.messages[0].text = "Local changed"; try conflictRecords.save(both)
        var cloud = Fixture.rows[both.id]!.record!
        cloud.call.messages[0].text = "Cloud changed"
        Fixture.rows[both.id] = CloudSyncRemote(id: both.id, revision: 2, deleted: false, updated_at: "2026-10-19", record: cloud)
        await conflictSync.synchronizeAutomatically(connection: connection)
        check(conflictSync.conflicts.contains(both.id), "simultaneous text edits remain explicit conflicts")
        check(conflictRecords.records[0].messages[0].text == "Local changed" && Fixture.rows[both.id]?.record?.call.messages[0].text == "Cloud changed", "automatic sync overwrites neither side of a conflict")

        Fixture.reset()
        let (retryRecords, retrySync, retryDirectory) = try make("retry")
        let retryRecord = record("Retry")
        try retryRecords.save(retryRecord); try retrySync.select(connection.id); try retrySync.setAutomaticSyncEnabled(true)
        Fixture.failAfterCommit = true
        await retrySync.synchronizeAutomatically(connection: connection)
        check(retrySync.hasPendingOperation && retrySync.errorMessage != nil, "uncertain network failure remains visible with pending journal")
        await retrySync.synchronizeAutomatically(connection: connection)
        check(Fixture.requests.count == 1 && retrySync.errorMessage != nil, "repeated automatic sync respects failure cooldown")
        let readsBeforeRestart = Fixture.ownerReads
        let restartedRetry = try CloudSyncStore(records: retryRecords, directory: retryDirectory)
        await restartedRetry.synchronizeAutomatically(connection: connection)
        check(Fixture.requests.count == 1 && Fixture.ownerReads == readsBeforeRestart, "automatic failure cooldown persists across store reload")
        let retryFile = retryDirectory.appendingPathComponent("state.json")
        var retryState = try JSONSerialization.jsonObject(with: Data(contentsOf: retryFile)) as! [String: Any]
        var retries = retryState["automaticRetries"] as! [String: [String: Any]]
        retries[connection.id.uuidString]?["retryAfter"] = Date.distantPast.timeIntervalSinceReferenceDate
        retryState["automaticRetries"] = retries
        try JSONSerialization.data(withJSONObject: retryState).write(to: retryFile, options: .atomic)
        let resumedRetry = try CloudSyncStore(records: retryRecords, directory: retryDirectory)
        await resumedRetry.synchronizeAutomatically(connection: connection)
        check(resumedRetry.errorMessage == nil && !resumedRetry.hasPendingOperation, "automatic retry safely completes journaled operation after cooldown")
        check(Fixture.requests.count == 2 && Fixture.requests[0] == Fixture.requests[1] && Fixture.rows[retryRecord.id]?.revision == 1, "retry reuses request identity without duplicate version")
        try retryRecords.save(record("Manual retry"))
        Fixture.failAfterCommit = true
        await resumedRetry.synchronizeAutomatically(connection: connection)
        await resumedRetry.continuePending(connection: connection)
        check(resumedRetry.errorMessage == nil && !resumedRetry.hasPendingOperation && Fixture.requests.count == 4,
              "manual retry remains available immediately during automatic cooldown")

        Fixture.reset()
        let (cancelRecords, cancelSync, _) = try make("cancel")
        var cancelledCall = record("Base")
        try cancelRecords.save(cancelledCall); try cancelSync.select(connection.id); try cancelSync.setAutomaticSyncEnabled(true)
        await cancelSync.synchronizeAutomatically(connection: connection)
        cancelledCall.messages[0].text = "Must not upload"
        try cancelRecords.save(cancelledCall)
        Fixture.requests = []; Fixture.delayGet = true; Fixture.enteredGet = false
        let task = Task { await cancelSync.synchronizeAutomatically(connection: connection) }
        while !Fixture.enteredGet { await Task.yield() }
        try cancelSync.setAutomaticSyncEnabled(false); task.cancel()
        await task.value
        check(Fixture.requests.isEmpty && !cancelSync.isBusy && !cancelSync.automaticSyncEnabled, "disable and cancellation prevent writes after in-flight read")
        Fixture.reset()
        let (bulkRecords, bulkSync, _) = try make("bulk-delete")
        let firstBackup = record("First backup"), secondBackup = record("Second backup")
        try bulkRecords.save(firstBackup); try bulkRecords.save(secondBackup)
        try bulkSync.select(connection.id); try bulkSync.setAutomaticSyncEnabled(true)
        await bulkSync.synchronizeAutomatically(connection: connection)
        Fixture.requests = []; Fixture.mutations = []; Fixture.backupOnlyDeletion = false
        let unsupported = await bulkSync.backupsForDeletion(connection: connection)
        check(unsupported == nil && bulkSync.errorMessage != nil && Fixture.requests.isEmpty, "old server blocks bulk deletion before any mutation")
        Fixture.backupOnlyDeletion = true
        let selection = await bulkSync.backupsForDeletion(connection: connection)
        check(selection?.count == 2 && Fixture.requests.isEmpty, "preparing the exact confirmation count only reads backups")
        let laterCloud = record("Arrived after confirmation"), laterLocal = record("New local call")
        Fixture.rows[laterCloud.id] = CloudSyncRemote(id: laterCloud.id, revision: 1, deleted: false, updated_at: "2026-10-20", record: CloudSyncDocument(call: laterCloud))
        try bulkRecords.save(laterLocal)
        await bulkSync.deleteAllRemote(connection: connection, selection: selection!)
        check(bulkSync.errorMessage == nil && !bulkSync.hasPendingOperation && selection!.allSatisfy { Fixture.rows[$0.id]?.deleted == true }, "bulk deletion commits each confirmed backup tombstone")
        check(Fixture.rows[laterCloud.id]?.deleted == false && bulkRecords.records.count == 3, "new unconfirmed cloud records and all local records remain")
        check(Fixture.mutations.count == 2 && Fixture.mutations.allSatisfy { $0.isDelete && $0.preserveCallMedia == true }, "bulk deletion uses the MCP-preserving deletion contract")
        Fixture.requests = []; Fixture.mutations = []
        await bulkSync.synchronizeAutomatically(connection: connection)
        check(bulkSync.errorMessage == nil && Fixture.mutations.count == 1 && Fixture.mutations[0].recordID == laterLocal.id, "next automatic sync uploads new calls without resurrecting deleted backups")
        check(bulkRecords.records.contains { $0.id == laterCloud.id }, "other cloud calls still download normally")

        Fixture.reset()
        let (bulkRetryRecords, bulkRetrySync, bulkDirectory) = try make("bulk-retry")
        let retryBackup = record("Keep local through deletion retry")
        try bulkRetryRecords.save(retryBackup); try bulkRetrySync.select(connection.id); try bulkRetrySync.setAutomaticSyncEnabled(true)
        await bulkRetrySync.synchronizeAutomatically(connection: connection)
        let staleSelection = await bulkRetrySync.backupsForDeletion(connection: connection)
        Fixture.rows[retryBackup.id] = CloudSyncRemote(id: retryBackup.id, revision: 2, deleted: false, updated_at: "2026-10-20", record: CloudSyncDocument(call: retryBackup))
        await bulkRetrySync.deleteAllRemote(connection: connection, selection: staleSelection!)
        check(bulkRetrySync.errorMessage != nil && !bulkRetrySync.hasPendingOperation && Fixture.rows[retryBackup.id]?.deleted == false, "changed remote revision rejects deletion without leaving an unretryable pending request")
        let currentSelection = await bulkRetrySync.backupsForDeletion(connection: connection)
        Fixture.failAfterCommit = true
        await bulkRetrySync.deleteAllRemote(connection: connection, selection: currentSelection!)
        check(bulkRetrySync.hasPendingOperation && bulkRetrySync.errorMessage != nil && bulkRetryRecords.records.count == 1, "uncertain deletion keeps its journal and local content")
        let previous = Fixture.mutations.last!
        let resumed = try CloudSyncStore(records: bulkRetryRecords, directory: bulkDirectory)
        await resumed.continuePending(connection: connection)
        check(resumed.errorMessage == nil && !resumed.hasPendingOperation && Fixture.mutations.last?.requestID == previous.requestID && Fixture.mutations.last?.preserveCallMedia == true, "restart retry preserves deletion identity and MCP-protection mode")
        print("\(pass) checks passed; no network or private data used")
    }
}
