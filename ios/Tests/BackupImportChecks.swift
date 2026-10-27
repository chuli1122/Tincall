// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@main
struct BackupImportChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TincallBackupChecks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = try CallRecordStore(directory: root.appendingPathComponent("source-records"))
        let sourceConfiguration = try LocalConfigurationStore(directory: root.appendingPathComponent("source-configuration"))
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let bytes = Data("Synthetic retained audio for import checks".utf8)
        let audio = root.appendingPathComponent("synthetic.wav")
        try bytes.write(to: audio)
        let a = try makeRecord(source, date: date, text: "Call A", audio: audio)
        let single = root.appendingPathComponent("single")
        try writeSingle(source, recordID: a.id, package: single)
        let b = try makeRecord(source, date: date, text: "Different call, identical timestamp", audio: audio)
        let global = root.appendingPathComponent("global")
        try await writeGlobal(configuration: sourceConfiguration, records: source, folder: global)

        let targetDirectory = root.appendingPathComponent("target-records")
        let target = try CallRecordStore(directory: targetDirectory)
        let first = try target.importRecord(from: single)
        precondition(first.imported && first.record.id != a.id && first.record.sourceRecordID == a.id)
        let repeated = try target.importRecord(from: single)
        precondition(!repeated.imported && repeated.record.id == first.record.id && target.records.count == 1)
        try target.updateSummary(recordID: first.record.id, status: .completed, text: "Newer local summary")
        let reopened = try CallRecordStore(directory: targetDirectory)
        let existing = reopened.records[0]
        let configuration = try LocalConfigurationStore(directory: root.appendingPathComponent("target-configuration"))
        let importedGlobal = try await GlobalBackup.importFolder(global, configuration: configuration, records: reopened)
        precondition(importedGlobal.records == 1 && importedGlobal.skippedRecords == 1 && reopened.records.count == 2)
        precondition(reopened.records.first(where: { $0.id == first.record.id }) == existing)
        precondition(Set(reopened.records.compactMap(\.sourceRecordID)) == Set([a.id, b.id]))
        try checkAudio(reopened, expected: bytes)
        let again = try await GlobalBackup.importFolder(global, configuration: configuration, records: reopened)
        precondition(again.records == 0 && again.skippedRecords == 2 && reopened.records.count == 2)
        let afterGlobal = try reopened.importRecord(from: single)
        precondition(!afterGlobal.imported && afterGlobal.record == existing)
        let restarted = try CallRecordStore(directory: targetDirectory)
        precondition(restarted.records.count == 2)
        try checkAudio(restarted, expected: bytes)

        // Re-exported imported calls retain the original source UUID across another fresh installation.
        let reexport = root.appendingPathComponent("reexport")
        try writeSingle(restarted, recordID: first.record.id, package: reexport)
        let other = try CallRecordStore(directory: root.appendingPathComponent("other-records"))
        let restored = try other.importRecord(from: reexport)
        let oldPackage = try other.importRecord(from: single)
        precondition(restored.imported && !oldPackage.imported && restored.record.id == oldPackage.record.id)
        precondition(other.records.count == 1 && other.records[0].summary == "Newer local summary")
        try checkAudio(other, expected: bytes)

        // Legacy imports lost the call ID, but retained message UUID and start time.
        let legacy = try CallRecordStore(directory: root.appendingPathComponent("legacy-records"))
        var legacyRecord = a
        legacyRecord.id = UUID(); legacyRecord.sourceRecordID = nil; legacyRecord.audioAssets = []
        legacyRecord.summaryStatus = .completed; legacyRecord.summary = "Legacy local edit"
        try legacy.save(legacyRecord)
        let matchedLegacy = try legacy.importRecord(from: single)
        precondition(!matchedLegacy.imported && matchedLegacy.record == legacyRecord && legacy.records.count == 1)
        let legacyGlobal = try await GlobalBackup.importFolder(global,
            configuration: LocalConfigurationStore(directory: root.appendingPathComponent("legacy-configuration")), records: legacy)
        precondition(legacyGlobal.records == 1 && legacyGlobal.skippedRecords == 1)
        precondition(legacy.records.contains(legacyRecord))

        // Cloud conflict copies are deliberate independent calls, never mistaken for a backup duplicate.
        let independent = try restarted.importRecord(from: single, asIndependentCopy: true)
        precondition(independent.imported && independent.record.sourceRecordID == independent.record.id)
        precondition(independent.record.id != existing.id && restarted.records.count == 3)
        let duplicateAfterCopy = try restarted.importRecord(from: single)
        precondition(!duplicateAfterCopy.imported && duplicateAfterCopy.record.id == existing.id && restarted.records.count == 3)
        try checkAudio(restarted, expected: bytes)
        let copyOnly = try CallRecordStore(directory: root.appendingPathComponent("independent-only"))
        _ = try copyOnly.importRecord(from: single, asIndependentCopy: true)
        let originalAfterCopy = try copyOnly.importRecord(from: single)
        precondition(originalAfterCopy.imported && copyOnly.records.count == 2)
        try checkAudio(copyOnly, expected: bytes)

        // A configuration write failure after staging rolls back only newly installed records.
        let rollbackRecords = try CallRecordStore(directory: root.appendingPathComponent("rollback-records"))
        let preserved = try rollbackRecords.importRecord(from: single).record
        let configDirectory = root.appendingPathComponent("rollback-configuration")
        let failingConfiguration = try LocalConfigurationStore(directory: configDirectory)
        try fm.createDirectory(at: configDirectory.appendingPathComponent("configuration.json"), withIntermediateDirectories: false)
        do {
            _ = try await GlobalBackup.importFolder(global, configuration: failingConfiguration, records: rollbackRecords)
            preconditionFailure("Expected configuration commit failure")
        } catch { }
        precondition(rollbackRecords.records == [preserved])
        let afterRollback = try CallRecordStore(directory: root.appendingPathComponent("rollback-records"))
        precondition(afterRollback.records == [preserved])
        try checkAudio(afterRollback, expected: bytes)
        let mediaChildren = try fm.contentsOfDirectory(at: afterRollback.mediaDirectory, includingPropertiesForKeys: nil)
        precondition(mediaChildren.map(\.lastPathComponent) == [preserved.id.uuidString])

        // Duplicate skipping still checks the archive's media completeness before accepting it.
        let media = single.appendingPathComponent("media")
        let clip = try fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)[0]
        try fm.removeItem(at: clip)
        do {
            _ = try restarted.importRecord(from: single)
            preconditionFailure("Corrupt duplicate backup must fail")
        } catch is TincallError { }
        precondition(restarted.records.count == 3)
        try checkAudio(restarted, expected: bytes)
        try await checkFormerLimits(root: root)
        print("PASS: single then global/repeated imports are idempotent after restart; stable UUIDs survive re-export; local edits/audio remain; equal timestamps stay distinct; legacy UUID fallback and independent cloud copies work; failed global commit rolls back only new records; duplicate archives retain safety checks")
    }

    @MainActor private static func checkFormerLimits(root: URL) async throws {
        let fm = FileManager.default
        let configuration = try LocalConfigurationStore(directory: root.appendingPathComponent("large-configuration"))
        let emptyConfigBytes = try configuration.storageBytes()
        precondition(emptyConfigBytes == 0)
        var role = CallRole(name: "Synthetic large backup")
        role.systemPrompt = String(repeating: "s", count: 65 * 1024 * 1024)
        try configuration.saveRole(role)
        let configBytes = try configuration.storageBytes()
        precondition(configBytes > 64 * 1024 * 1024)
        let records = try CallRecordStore(directory: root.appendingPathComponent("large-records"))
        var messages = (0..<50_001).map { _ in CallMessage(turnID: UUID(), role: .user, text: "Synthetic") }
        messages[0].text = String(repeating: "t", count: 9 * 1024 * 1024)
        let record = CallRecord(roleID: role.id, roleName: role.name, startedAt: Date(), messages: messages)
        try records.save(record)
        let sparseAudio = root.appendingPathComponent("large-synthetic.wav")
        _ = fm.createFile(atPath: sparseAudio.path, contents: Data([1]))
        let file = try FileHandle(forWritingTo: sparseAudio)
        let audioSize = UInt64(2 * 1024 * 1024 * 1024) + 1
        try file.truncate(atOffset: audioSize)
        try file.close()
        _ = try records.saveAudio(recordID: record.id, segment: VoiceAudioSegment(id: UUID(), messageID: messages[0].id, segmentIndex: 0, fileURL: sparseAudio, duration: 1))
        let single = root.appendingPathComponent("large-single")
        try writeSingle(records, recordID: record.id, package: single)
        let singleTarget = try CallRecordStore(directory: root.appendingPathComponent("large-single-target"))
        let singleResult = try singleTarget.importRecord(from: single)
        precondition(singleResult.imported && singleResult.record.messages.count == messages.count)
        precondition(singleResult.record.messages[0].text == messages[0].text)
        let singleUsage = try singleTarget.storageUsage()
        precondition(singleUsage.textBytes > 8 * 1024 * 1024 && singleUsage.audioBytes == Int64(audioSize))
        let folder = root.appendingPathComponent("large-global")
        try await writeGlobal(configuration: configuration, records: records, folder: folder)
        let targetConfiguration = try LocalConfigurationStore(directory: root.appendingPathComponent("large-target-configuration"))
        let target = try CallRecordStore(directory: root.appendingPathComponent("large-global-target"))
        let result = try await GlobalBackup.importFolder(folder, configuration: targetConfiguration, records: target)
        precondition(result.contacts == 1 && result.records == 1)
        precondition(targetConfiguration.roles[0].systemPrompt == role.systemPrompt)
        precondition(target.records[0].messages.count == messages.count && target.records[0].messages[0].text == messages[0].text)
        let usage = try target.storageUsage()
        precondition(usage.audioBytes == Int64(audioSize))
        print("PASS: single and global round trips exceed former 8 MB / 64 MB / 2 GB and 50,000-message limits; configuration and media sizes remain accurate")
    }

    @MainActor private static func makeRecord(_ store: CallRecordStore, date: Date, text: String, audio: URL) throws -> CallRecord {
        let user = CallMessage(turnID: UUID(), role: .user, text: text)
        let record = CallRecord(roleID: UUID(), roleName: "Synthetic", startedAt: date, endedAt: date.addingTimeInterval(30), messages: [user])
        try store.save(record)
        _ = try store.saveAudio(recordID: record.id, segment: VoiceAudioSegment(id: UUID(), messageID: user.id, segmentIndex: 0, fileURL: audio, duration: 1))
        return store.records.first { $0.id == record.id }!
    }

    @MainActor private static func writeSingle(_ store: CallRecordStore, recordID: UUID, package: URL) throws {
        let export = try store.exportRecord(recordID)
        let media = package.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try export.manifest.write(to: package.appendingPathComponent("record.json"))
        for (name, source) in export.media { try FileManager.default.copyItem(at: source, to: media.appendingPathComponent(name)) }
    }

    @MainActor private static func writeGlobal(configuration: LocalConfigurationStore, records: CallRecordStore, folder: URL) async throws {
        let export = try await GlobalBackup.export(configuration: configuration, records: records)
        let recordDirectory = folder.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
        try export.manifest.write(to: folder.appendingPathComponent("backup.json"))
        for record in export.records {
            let package = recordDirectory.appendingPathComponent(record.id.uuidString)
            let media = package.appendingPathComponent("media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try record.manifest.write(to: package.appendingPathComponent("record.json"))
            for (name, source) in record.media { try FileManager.default.copyItem(at: source, to: media.appendingPathComponent(name)) }
        }
    }

    @MainActor private static func checkAudio(_ store: CallRecordStore, expected: Data) throws {
        for record in store.records {
            precondition(record.audioAssets.count == 1)
            let bytes = try Data(contentsOf: store.audioURL(record.audioAssets[0], recordID: record.id))
            precondition(bytes == expected)
        }
    }
}
