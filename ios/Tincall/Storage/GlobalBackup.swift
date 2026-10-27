// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// A folder backup of public configuration, contacts, call text and retained audio.
/// Credentials are never read from Keychain by this format.
enum GlobalBackup {
    private struct Manifest: Codable, Sendable {
        let format: String
        let version: Int
        let configuration: LocalConfigurationStore.Configuration
        let recordIDs: [UUID]
    }

    private struct RecordArchive: Codable, Sendable {
        let version: Int
        let record: CallRecord
    }

    struct RecordExport: Sendable {
        let id: UUID
        let manifest: Data
        let media: [String: URL]
    }

    struct Export: Sendable {
        let manifest: Data
        let records: [RecordExport]
        let fileWrapper: PreparedFileWrapper
    }

    /// FileWrapper is a reference type, but the tree is immutable after the
    /// worker builds it. Keeping it behind this explicit boundary prevents the
    /// document exporter from rereading media on the main actor.
    final class PreparedFileWrapper: @unchecked Sendable {
        let value: FileWrapper
        init(_ value: FileWrapper) { self.value = value }
    }

    struct ImportResult {
        let connections: Int
        let contacts: Int
        let records: Int
        let skippedRecords: Int
        var temporaryCleanupFailed = false
    }

    @MainActor static func export(configuration: LocalConfigurationStore, records: CallRecordStore) async throws -> Export {
        let snapshot = try records.backupSnapshot()
        let config = try configuration.backupSnapshot()
        let recordsValue = snapshot.records
        let media = snapshot.media
        return try await Task.detached(priority: .userInitiated) {
            let manifest = try JSONEncoder().encode(Manifest(format: "Tincall", version: 1,
                configuration: config, recordIDs: recordsValue.map(\.id)))
            var exports: [RecordExport] = []
            var calls: [String: FileWrapper] = [:]
            for record in recordsValue {
                let recordManifest = try JSONEncoder().encode(RecordArchive(version: 1, record: record))
                var wrappers: [String: FileWrapper] = [:]
                for (name, source) in media[record.id] ?? [:] {
                    let file = try FileWrapper(url: source, options: [])
                    file.preferredFilename = name
                    wrappers[name] = file
                }
                let recordWrapper = FileWrapper(directoryWithFileWrappers: [
                    "record.json": FileWrapper(regularFileWithContents: recordManifest),
                    "media": FileWrapper(directoryWithFileWrappers: wrappers)
                ])
                calls[record.id.uuidString] = recordWrapper
                exports.append(RecordExport(id: record.id, manifest: recordManifest, media: media[record.id] ?? [:]))
            }
            let wrapper = FileWrapper(directoryWithFileWrappers: [
                "backup.json": FileWrapper(regularFileWithContents: manifest),
                "records": FileWrapper(directoryWithFileWrappers: calls)
            ])
            return Export(manifest: manifest, records: exports, fileWrapper: PreparedFileWrapper(wrapper))
        }.value
    }

    @MainActor static func importFolder(_ folder: URL, configuration: LocalConfigurationStore, records: CallRecordStore) async throws -> ImportResult {
        let fm = FileManager.default
        try checkDirectory(folder)
        let source = folder
        let stagedInput = try await Task.detached(priority: .userInitiated) {
            let manifestURL = source.appendingPathComponent("backup.json")
            let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TincallImportInput-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: staging)
            return (manifestData, manifest, staging)
        }.value
        defer { try? fm.removeItem(at: stagedInput.2) }
        let manifestSize = stagedInput.0.count
        let manifest = stagedInput.1
        guard manifest.format == "Tincall", manifest.version == 1 else { throw TincallError(message: String(localized: "不支持此全局备份版本")) }
        guard Set(manifest.recordIDs).count == manifest.recordIDs.count else { throw TincallError(message: String(localized: "全局备份记录清单无效")) }
        let plan = try configuration.prepareImport(manifest.configuration)
        let expectedConfiguration = try configuration.backupSnapshot()
        let preparedConfiguration = try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("TincallImportConfiguration-\(UUID().uuidString).json")
            let data = try JSONEncoder().encode(plan.configuration)
            try data.write(to: url, options: .atomic)
            return url
        }.value
        defer { try? fm.removeItem(at: preparedConfiguration) }
        let recordDirectory = stagedInput.2.appendingPathComponent("records", isDirectory: true)
        try checkDirectory(recordDirectory)
        let children = try fm.contentsOfDirectory(at: recordDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard Set(children.map(\.lastPathComponent)) == Set(manifest.recordIDs.map(\.uuidString)), children.count == manifest.recordIDs.count else {
            throw TincallError(message: String(localized: "全局备份记录与清单不完整"))
        }
        var requiredBytes = Int64(manifestSize)
        let packages = try manifest.recordIDs.map { id -> URL in
            let package = recordDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try checkDirectory(package)
            requiredBytes += Int64(try fileSize(package.appendingPathComponent("record.json")))
            let media = package.appendingPathComponent("media", isDirectory: true)
            try checkDirectory(media)
            for url in try fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                requiredBytes += Int64(try fileSize(url))
            }
            return package
        }
        try records.checkAvailableSpace(requiredBytes: requiredBytes)
        let staging = fm.temporaryDirectory.appendingPathComponent("TincallImport-\(UUID().uuidString)", isDirectory: true)
        var installed: [CallRecord] = []
        do {
            let staged = try CallRecordStore(directory: staging, strictLoading: true)
            for package in packages {
                let imported = try staged.importRecord(from: package)
                guard imported.imported else { continue }
                var record = imported.record
                record.roleID = plan.roleIDs[record.roleID] ?? record.roleID
                record.externalConnectionID = record.externalConnectionID.flatMap { plan.connectionIDs[$0] }
                try staged.save(record)
            }
            installed = try records.installImportedRecords(from: staged, deduplicate: true)
            do { try configuration.commitImport(plan, preparedFile: preparedConfiguration, expected: expectedConfiguration) }
            catch {
                do { try records.rollbackImportedRecords(installed) }
                catch { throw TincallError(message: String(localized: "配置导入未保存，部分新记录清理失败；原有数据保留。")) }
                throw error
            }
        } catch {
            if fm.fileExists(atPath: staging.path) {
                do { try fm.removeItem(at: staging) }
                catch { throw TincallError(message: String(localized: "导入未完成，临时副本清理失败；原有数据保留。")) }
            }
            throw error
        }
        var result = ImportResult(connections: plan.addedConnections, contacts: plan.addedRoles,
                                  records: installed.count, skippedRecords: packages.count - installed.count)
        do { try fm.removeItem(at: staging) }
        catch { result.temporaryCleanupFailed = true }
        return result
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw TincallError(message: String(localized: "备份文件缺失、为空或包含符号链接"))
        }
        return size
    }

    private static func checkDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw TincallError(message: String(localized: "请选择本地备份文件夹")) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw TincallError(message: String(localized: "备份目录无效或包含符号链接")) }
    }
}
