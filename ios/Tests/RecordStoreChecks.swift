// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct RecordStoreChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TincallRecordChecks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try checkUnreadableRecords(root.appendingPathComponent("unreadable"))
        let store = try CallRecordStore(directory: root.appendingPathComponent("records"))
        let emptyUsage = try store.storageUsage()
        precondition(emptyUsage.textBytes == 0 && emptyUsage.imageBytes == 0 && emptyUsage.audioBytes == 0)
        let user = CallMessage(turnID: UUID(), role: .user, text: "Synthetic storage check")
        var original = CallRecord(roleID: UUID(), roleName: "Synthetic", startedAt: Date().addingTimeInterval(-10), endedAt: Date(), messages: [user])
        original.externalCallID = original.id
        original.externalEventCursor = 8
        original.externalEpoch = 2
        original.externalReplyID = UUID()
        original.externalAnswerRequestID = UUID()
        original.externalPendingInput = ExternalPendingInput(requestID: UUID(), messageID: user.id, replyMessageID: UUID(), epoch: 2)
        original.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: 2, endsCall: true)
        original.queuedInputIDs = [user.id]
        try store.save(original)
        let imageBytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let imageAssets = try store.saveImages(recordID: original.id, messageID: user.id, images: [imageBytes])
        original.messages[0].images = imageAssets
        try store.save(original)
        let source = root.appendingPathComponent("sample.wav")
        let bytes = Data("Synthetic bytes for storage round trip only".utf8)
        try bytes.write(to: source)
        _ = try store.saveAudio(recordID: original.id, segment: VoiceAudioSegment(id: UUID(), messageID: user.id, segmentIndex: 0, fileURL: source, duration: 1))
        let exported = try store.exportRecord(original.id)
        let usage = try store.storageUsage()
        let savedTextBytes = try JSONEncoder().encode(store.records[0]).count
        precondition(usage.textBytes == Int64(savedTextBytes))
        precondition(usage.imageBytes == Int64(imageBytes.count) && usage.audioBytes == Int64(bytes.count))
        let package = root.appendingPathComponent("export")
        try fm.createDirectory(at: package.appendingPathComponent("media"), withIntermediateDirectories: true)
        try exported.manifest.write(to: package.appendingPathComponent("record.json"))
        for (name, url) in exported.media { try fm.copyItem(at: url, to: package.appendingPathComponent("media").appendingPathComponent(name)) }
        let result = try store.importRecord(from: package, asIndependentCopy: true)
        precondition(result.imported)
        let imported = result.record
        precondition(imported.id != original.id)
        precondition(imported.sourceRecordID == imported.id)
        precondition(imported.externalCallID == nil && imported.externalEventCursor == nil && imported.externalEpoch == nil)
        precondition(imported.externalPendingInput == nil && imported.externalPendingControl == nil && imported.externalReplyID == nil && imported.externalAnswerRequestID == nil)
        precondition(imported.queuedInputIDs == nil)
        precondition(imported.messages[0].text == original.messages[0].text)
        let importedImage = try required(imported.messages[0].images?.first)
        let importedImageURL = try store.imageURL(importedImage, recordID: imported.id, messageID: user.id)
        let copiedImage = try Data(contentsOf: importedImageURL)
        precondition(copiedImage == imageBytes)
        do {
            var badImage = importedImage
            badImage.relativePath = "../escape.jpg"
            _ = try store.imageURL(badImage, recordID: imported.id, messageID: user.id)
            preconditionFailure("Unsafe image path must fail")
        } catch is TincallError { }
        let asset = try required(imported.audioAssets.first)
        let importedAudio = try store.audioURL(asset, recordID: imported.id)
        let copied = try Data(contentsOf: importedAudio)
        precondition(copied == bytes)
        try store.updateSummary(recordID: imported.id, status: .completed, text: "Edited summary")
        let reloaded = try CallRecordStore(directory: root.appendingPathComponent("records"))
        precondition(reloaded.records.first(where: { $0.id == imported.id })?.summary == "Edited summary")
        store.canDeleteRecord = { _ in false }
        do {
            try store.delete(recordID: imported.id)
            preconditionFailure("A pending save must block deletion")
        } catch is TincallError { }
        precondition(fm.fileExists(atPath: importedAudio.path))
        store.canDeleteRecord = { _ in true }
        var deletedID: UUID?
        store.onDeleteRecord = { deletedID = $0 }
        try store.delete(recordID: imported.id)
        precondition(deletedID == imported.id)
        precondition(!fm.fileExists(atPath: importedAudio.path))
        precondition(!fm.fileExists(atPath: importedImageURL.path))
        try store.reload()
        precondition(store.records.map(\.id) == [original.id])
        let remainingUsage = try store.storageUsage()
        precondition(remainingUsage.textBytes == usage.textBytes && remainingUsage.imageBytes == usage.imageBytes && remainingUsage.audioBytes == usage.audioBytes)
        do {
            try store.delete(recordID: original.id)
            preconditionFailure("A live control outbox must not be deleted")
        } catch is TincallError { }
        precondition(store.records.count == 1)
        let remainingAudio = try store.audioURL(try required(store.records[0].audioAssets.first), recordID: original.id)
        precondition(fm.fileExists(atPath: remainingAudio.path))
        var queuedOnly = original
        queuedOnly.externalPendingControl = nil
        queuedOnly.externalPendingInput = nil
        try store.save(queuedOnly)
        do {
            try store.delete(recordID: queuedOnly.id)
            preconditionFailure("Queued text must not be deleted before delivery")
        } catch is TincallError { }
        precondition(fm.fileExists(atPath: remainingAudio.path))
        precondition(store.records.first?.queuedInputIDs == [user.id])
        try checkInterruptedRecovery(root.appendingPathComponent("recovery"))
        try checkLocalCleanup(root.appendingPathComponent("cleanup"))
        print("PASS: import detaches remote and queued state; media and summary round trip; deletion blocks pending controls and queued text; file sizes reflect text, images and retained audio before and after deletion")
    }

    @MainActor private static func checkUnreadableRecords(_ directory: URL) throws {
        let original = try CallRecordStore(directory: directory)
        let good = CallRecord(roleID: UUID(), roleName: "Synthetic readable", startedAt: Date().addingTimeInterval(-10), endedAt: Date())
        let damaged = CallRecord(roleID: UUID(), roleName: "Synthetic unreadable", startedAt: Date().addingTimeInterval(-10), endedAt: Date())
        try original.save(good)
        try original.save(damaged)
        let damagedURL = directory.appendingPathComponent("\(damaged.id.uuidString).json")
        let bytes = Data("{truncated synthetic record".utf8)
        try bytes.write(to: damagedURL)
        let reopened = try CallRecordStore(directory: directory)
        precondition(reopened.records == [good], "One unreadable record must not hide healthy history")
        let retained = try Data(contentsOf: damagedURL)
        precondition(retained == bytes, "Unreadable records must remain untouched")
        precondition(reopened.storageIssue != nil && reopened.unavailableRecordIDs == [damaged.id])
        precondition(reopened.canModifyRecord(good.id) && !reopened.canModifyRecord(damaged.id))
        try expectUnavailable { try reopened.save(damaged) }
        try expectUnavailable { try reopened.delete(recordID: damaged.id) }
        try expectUnavailable { _ = try reopened.exportRecord(damaged.id) }
        try expectUnavailable { try reopened.requireCompleteLoading() }
        try expectUnavailable { _ = try reopened.storageUsage() }
        try expectUnavailable { try reopened.clearLocalData(.records) }
        let readableExport = try reopened.exportRecord(good.id)
        let package = directory.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("media"), withIntermediateDirectories: true)
        try readableExport.manifest.write(to: package.appendingPathComponent("record.json"))
        try expectUnavailable { _ = try reopened.importRecord(from: package) }
        let clean = try CallRecordStore(directory: directory.appendingPathComponent("clean"))
        try expectUnavailable { _ = try clean.installImportedRecords(from: reopened) }
        do {
            _ = try CallRecordStore(directory: directory, strictLoading: true)
            preconditionFailure("Staging must not accept a partially readable store")
        } catch { }
        let stillRetained = try Data(contentsOf: damagedURL)
        precondition(stillRetained == bytes && reopened.records == [good] && clean.records.isEmpty)

        // Valid JSON with a newer enum is unavailable, not evidence of corruption.
        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(damaged)) as! [String: Any]
        future["summaryStatus"] = "synthetic_future_status"
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        try futureBytes.write(to: damagedURL)
        try reopened.reload()
        precondition(reopened.records == [good] && reopened.unavailableRecordIDs == [damaged.id])
        let retainedFuture = try Data(contentsOf: damagedURL)
        precondition(retainedFuture == futureBytes)

        // A read failure is kept in place too, rather than renamed as corrupt.
        try FileManager.default.removeItem(at: damagedURL)
        try FileManager.default.createDirectory(at: damagedURL, withIntermediateDirectories: false)
        try reopened.reload()
        precondition(reopened.records == [good] && reopened.unavailableRecordIDs == [damaged.id])
        try expectUnavailable { try reopened.save(damaged) }
        try FileManager.default.removeItem(at: damagedURL)
        try JSONEncoder().encode(damaged).write(to: damagedURL)
        try reopened.reload()
        precondition(reopened.storageIssue == nil && reopened.unavailableRecordIDs.isEmpty)

        var active = good
        active.endedAt = nil
        try reopened.save(active)
        let activeURL = directory.appendingPathComponent("\(active.id.uuidString).json")
        let activeBytes = try Data(contentsOf: activeURL)
        let unknown = directory.appendingPathComponent("unidentified.json")
        try bytes.write(to: unknown)
        try reopened.reload()
        precondition(reopened.hasUnidentifiedUnavailableRecords && !reopened.canModifyRecord(active.id))
        try reopened.recoverUnfinishedCalls()
        try expectUnavailable { try reopened.save(good) }
        try expectUnavailable { try reopened.delete(recordID: active.id) }
        let unchangedActive = try Data(contentsOf: activeURL)
        let unchangedUnknown = try Data(contentsOf: unknown)
        precondition(unchangedActive == activeBytes && unchangedUnknown == bytes, "Unknown ownership must leave all stored records untouched, including launch recovery")
        print("PASS: unreadable, newer-schema and failed-read files preserve healthy history and original files; unsafe writes, cleanup, import and incomplete export are blocked; staging remains strict")
    }

    private static func expectUnavailable(_ operation: () throws -> Void) throws {
        do { try operation(); preconditionFailure("Unavailable record state must fail safely") }
        catch is TincallError { }
    }

    @MainActor private static func checkLocalCleanup(_ directory: URL) throws {
        let fm = FileManager.default
        let store = try CallRecordStore(directory: directory)
        let message = CallMessage(turnID: UUID(), role: .user, text: "Keep synthetic text")
        var record = CallRecord(roleID: UUID(), roleName: "Synthetic cleanup", startedAt: Date().addingTimeInterval(-10), endedAt: Date(), messages: [message], summaryStatus: .completed, summary: "Keep summary")
        try store.save(record)
        record.messages[0].images = try store.saveImages(recordID: record.id, messageID: message.id, images: [Data([0xff, 0xd8, 0xff, 0xd9])])
        try store.save(record)
        let image = try store.imageURL(record.messages[0].images![0], recordID: record.id, messageID: message.id)
        let source = directory.appendingPathComponent("synthetic.wav")
        try Data("Synthetic cleanup audio".utf8).write(to: source)
        let audio = try store.saveAudio(recordID: record.id, segment: VoiceAudioSegment(id: UUID(), messageID: message.id, segmentIndex: 0, fileURL: source, duration: 1))
        let audioURL = try store.audioURL(audio, recordID: record.id)
        record = store.records[0]
        for category in CallRecordStore.LocalDataCategory.allCases {
            store.canDeleteRecord = { _ in false }
            do { try store.clearLocalData(category); preconditionFailure("Busy records must block all categories") }
            catch is TincallError { }
        }
        precondition(store.records[0] == record && fm.fileExists(atPath: audioURL.path) && fm.fileExists(atPath: image.path))
        store.canDeleteRecord = { _ in true }
        var pending = record
        pending.queuedInputIDs = [message.id]
        try store.save(pending)
        do { try store.clearLocalData(.images); preconditionFailure("Queued messages must block cleanup") }
        catch is TincallError { }
        try store.save(record)

        // A real filesystem write failure after staging must restore the files and original in-memory index.
        let manifest = directory.appendingPathComponent("\(record.id.uuidString).json")
        let retained = directory.appendingPathComponent("retained-manifest")
        try fm.moveItem(at: manifest, to: retained)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { try store.clearLocalData(.audio); preconditionFailure("Saving over a directory must fail") }
        catch { }
        precondition(store.records[0] == record && fm.fileExists(atPath: audioURL.path))
        try fm.removeItem(at: manifest)
        try fm.moveItem(at: retained, to: manifest)

        var invalidated: [UUID] = []
        store.onDeleteRecord = { invalidated.append($0) }
        try store.clearLocalData(.audio)
        precondition(!fm.fileExists(atPath: audioURL.path) && fm.fileExists(atPath: image.path))
        precondition(store.records[0].audioAssets.isEmpty && store.records[0].messages == record.messages && store.records[0].summary == record.summary)
        precondition(invalidated == [record.id])
        let audioUsage = try store.storageUsage()
        precondition(audioUsage.audioBytes == 0 && audioUsage.imageBytes == 4)
        try store.clearLocalData(.images)
        precondition(!fm.fileExists(atPath: image.path) && store.records[0].messages[0].images == nil)
        precondition(store.records[0].messages[0].text == message.text && store.records[0].summary == record.summary)
        let reopened = try CallRecordStore(directory: directory)
        precondition(reopened.records == store.records)
        let imageUsage = try reopened.storageUsage()
        precondition(imageUsage.audioBytes == 0 && imageUsage.imageBytes == 0 && imageUsage.textBytes > 0)
        try reopened.clearLocalData(.records)
        precondition(reopened.records.isEmpty)
        let empty = try CallRecordStore(directory: directory)
        precondition(empty.records.isEmpty)
        print("PASS: separate audio/image/all-record cleanup persists, preserves other categories, evicts cached snapshots, blocks pending work, and rolls back staged media on index write failure")
    }

    @MainActor private static func checkInterruptedRecovery(_ directory: URL) throws {
        let store = try CallRecordStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_000)
        var active = CallRecord(roleID: UUID(), roleName: "Synthetic unfinished", startedAt: start,
            messages: [CallMessage(turnID: UUID(), role: .assistant, text: "Saved partial reply", status: .generating)],
            summaryStatus: .generating, lastActiveAt: start.addingTimeInterval(25), recordedActiveDuration: 18)
        active.queuedInputIDs = [UUID()]
        try store.save(active)
        let legacy = CallRecord(roleID: UUID(), roleName: "Synthetic legacy", startedAt: start)
        try store.save(legacy)
        var remote = active
        remote.id = UUID()
        remote.externalCallID = remote.id
        remote.externalPendingInput = ExternalPendingInput(requestID: UUID(), messageID: active.messages[0].id, replyMessageID: UUID(), epoch: 2)
        remote.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: 2, endsCall: true)
        remote.externalEventCursor = 8
        try store.save(remote)
        let ended = CallRecord(roleID: UUID(), roleName: "Synthetic ended", startedAt: start, endedAt: start.addingTimeInterval(30))
        try store.save(ended)
        precondition(store.records.count == 4 && store.finishedRecords.map(\.id) == [ended.id], "ongoing calls stay durable but are absent from history")
        let staged = try CallRecordStore(directory: directory)
        precondition(staged.records.filter { !$0.isFinished }.count == 3, "opening storage must not finish staged or live calls")
        try staged.recoverUnfinishedCalls()
        let restored = try CallRecordStore(directory: directory)
        let interrupted = try required(restored.records.first { $0.id == active.id })
        precondition(interrupted.endedAbnormally == true && interrupted.endedAt == nil && interrupted.isFinished)
        precondition(interrupted.lastActiveAt == active.lastActiveAt && interrupted.recordedDuration == 18, "recovery cannot invent an end time or count an inactive resume gap")
        precondition(interrupted.messages[0].status == .interrupted && interrupted.queuedInputIDs == nil && interrupted.summaryStatus == .failed)
        let old = try required(restored.records.first { $0.id == legacy.id })
        precondition(old.endedAbnormally == true && old.recordedDuration == nil && old.endedAt == nil, "legacy missing checkpoint means unknown duration")
        let pending = try required(restored.records.first { $0.id == remote.id })
        precondition(pending.externalEventCursor == 8 && pending.externalPendingInput == remote.externalPendingInput && pending.externalPendingControl == remote.externalPendingControl)
        precondition(pending.messages[0].status == .generating && pending.queuedInputIDs == remote.queuedInputIDs, "remote resumption retains reply and cancellation state")
        precondition(restored.records.first { $0.id == ended.id } == ended && restored.finishedRecords.count == 4)
        try restored.recoverUnfinishedCalls()
        precondition(restored.records.first { $0.id == active.id } == interrupted, "launch recovery is idempotent")
        let exported = try restored.exportRecord(interrupted.id)
        let package = directory.appendingPathComponent("interrupted-export", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
        try exported.manifest.write(to: package.appendingPathComponent("record.json"))
        let imported = try restored.importRecord(from: package, asIndependentCopy: true).record
        precondition(imported.isFinished && imported.endedAt == nil && imported.endedAbnormally == true && imported.recordedDuration == 18, "backup round trip preserves the unknown ending and interrupted history state")
        let legacyExport = try store.exportRecord(legacy.id)
        try legacyExport.manifest.write(to: package.appendingPathComponent("record.json"))
        let legacyImport = try restored.importRecord(from: package, asIndependentCopy: true).record
        precondition(legacyImport.isFinished && legacyImport.endedAbnormally == true && legacyImport.endedAt == nil && legacyImport.recordedDuration == nil, "an old unfinished archive is detached history, never a hidden active session")
        var invalid = interrupted
        invalid.recordedActiveDuration = -1
        do {
            try restored.save(invalid)
            preconditionFailure("negative observed duration must fail")
        } catch is TincallError { }
        print("PASS: durable active calls stay out of history; explicit launch recovery preserves unknown end times, observed duration, remote resumption, and summary retry state")
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw TincallError(message: "Missing synthetic fixture") }
        return value
    }
}
