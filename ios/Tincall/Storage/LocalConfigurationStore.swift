// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

struct LocalUserProfile: Codable, Equatable, Sendable {
    var name: String = String(localized: "我")
    var avatarData: Data?
}

@MainActor @Observable
final class LocalConfigurationStore {
    private(set) var connections: [ConnectionProfile] = []
    private(set) var roles: [CallRole] = []
    private(set) var retention = AudioRetention()
    private(set) var userProfile = LocalUserProfile()
    private(set) var speechRecognitionCorrections: [SpeechRecognitionCorrection] = []
    private(set) var defaultSTTConnectionID: UUID?
    private(set) var contactSyncIssue: String?
    private(set) var contactSyncIssues: [UUID: String] = [:]
    @ObservationIgnored let contactReader = SystemContactReader()
    @ObservationIgnored private var isRefreshingContacts = false
    @ObservationIgnored private var refreshContactsAgain = false
    private let fileURL: URL

    struct Configuration: Codable, Sendable {
        var connections: [ConnectionProfile]
        var roles: [CallRole]
        var retention: AudioRetention
        var defaultSTTConnectionID: UUID?
        var userProfile: LocalUserProfile? = nil
        var speechRecognitionCorrections: [SpeechRecognitionCorrection]? = nil

        /// Preserve old effective identities once, then discard service-wide defaults.
        mutating func migrateExternalIdentities() -> Bool {
            guard connections.contains(where: { $0.externalRoleID != nil || $0.externalRoleName != nil }) else { return false }
            for index in roles.indices where roles[index].effectiveCallMode != .standalone && roles[index].externalRoleID == nil {
                guard let connection = connections.first(where: { $0.id == roles[index].externalConnectionID }),
                      let identity = connection.externalRoleID else { continue }
                roles[index].externalRoleID = identity
                roles[index].externalRoleName = connection.externalRoleName
            }
            for index in connections.indices {
                connections[index].externalRoleID = nil
                connections[index].externalRoleName = nil
            }
            return true
        }
    }

    init(directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Tincall", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("configuration.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            var saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fileURL))
            let migrated = saved.migrateExternalIdentities()
            connections = saved.connections
            roles = saved.roles
            retention = saved.retention
            defaultSTTConnectionID = saved.defaultSTTConnectionID
            userProfile = saved.userProfile ?? LocalUserProfile()
            speechRecognitionCorrections = try validatedCorrections(saved.speechRecognitionCorrections ?? [])
            if migrated {
                try persist(connections: connections, roles: roles, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID)
            }
        }
    }

    func saveConnection(_ connection: ConnectionProfile) throws {
        guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TincallError(message: String(localized: "请填写连接名称"))
        }
        if connection.id == defaultSTTConnectionID, !connection.provider.isSpeechRecognition {
            throw TincallError(message: String(localized: "此连接用于全局语音识别，不能更改供应商"))
        }
        if let old = connections.first(where: { $0.id == connection.id }), old.provider != connection.provider,
           roles.contains(where: { $0.modelConnectionID == old.id || $0.summaryConnectionID == old.id || $0.sttConnectionID == old.id || $0.ttsConnectionID == old.id || $0.externalConnectionID == old.id }) {
            throw TincallError(message: String(localized: "此连接已被联系人使用，不能更改供应商"))
        }
        var next = connections.filter { $0.id != connection.id }
        next.append(connection)
        try persist(connections: next, roles: roles, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID)
    }

    func deleteConnection(_ id: UUID) throws {
        let nextRoles = roles.map { role in
            var role = role
            if role.modelConnectionID == id { role.modelConnectionID = nil }
            if role.summaryConnectionID == id { role.summaryConnectionID = nil }
            if role.sttConnectionID == id { role.sttConnectionID = nil }
            if role.ttsConnectionID == id { role.ttsConnectionID = nil }
            if role.externalConnectionID == id { role.externalConnectionID = nil }
            return role
        }
        try persist(connections: connections.filter { $0.id != id }, roles: nextRoles, retention: retention,
                    defaultSTTConnectionID: defaultSTTConnectionID == id ? nil : defaultSTTConnectionID)
    }

    func saveRole(_ role: CallRole) throws {
        var role = role
        role.name = role.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateRole(role, connections: connections)
        var next = roles
        if let index = next.firstIndex(where: { $0.id == role.id }) {
            // An editor opened before contact refresh must not discard its saved address.
            role.systemCallPhoneNumber = next[index].systemCallPhoneNumber ?? role.systemCallPhoneNumber
            next[index] = role
        } else {
            next.append(role)
        }
        try persist(connections: connections, roles: next, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID)
    }

    func deleteRole(_ id: UUID) throws {
        try persist(connections: connections, roles: roles.filter { $0.id != id }, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID)
    }

    func saveRetention(_ value: AudioRetention) throws {
        try persist(connections: connections, roles: roles, retention: value, defaultSTTConnectionID: defaultSTTConnectionID)
    }

    func saveDefaultSTTConnection(_ id: UUID?) throws {
        if let id, !connections.contains(where: { $0.id == id && $0.provider.isSpeechRecognition }) {
            throw TincallError(message: String(localized: "请选择有效的识别连接"))
        }
        try persist(connections: connections, roles: roles, retention: retention, defaultSTTConnectionID: id)
    }

    func saveUserProfile(_ value: LocalUserProfile) throws {
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name.isEmpty { value.name = String(localized: "我") }
        try persist(connections: connections, roles: roles, retention: retention,
                    defaultSTTConnectionID: defaultSTTConnectionID, userProfile: value)
    }

    func saveSpeechRecognitionCorrections(_ value: [SpeechRecognitionCorrection]) throws {
        let value = try validatedCorrections(value)
        try persist(connections: connections, roles: roles, retention: retention,
                    defaultSTTConnectionID: defaultSTTConnectionID, speechRecognitionCorrections: value)
    }

    func saveSpeechRecognitionCorrection(_ value: SpeechRecognitionCorrection) throws {
        var next = speechRecognitionCorrections
        if let index = next.firstIndex(where: { $0.id == value.id }) {
            next[index] = value
        } else {
            next.append(value)
        }
        try saveSpeechRecognitionCorrections(next)
    }

    func deleteSpeechRecognitionCorrection(_ id: UUID) throws {
        guard speechRecognitionCorrections.contains(where: { $0.id == id }) else { return }
        try saveSpeechRecognitionCorrections(speechRecognitionCorrections.filter { $0.id != id })
    }

    private func validatedCorrections(_ rules: [SpeechRecognitionCorrection]) throws -> [SpeechRecognitionCorrection] {
        var sources: Set<String> = []
        var ids: Set<UUID> = []
        return try rules.map { rule in
            var rule = rule
            rule.source = rule.source.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.source.isEmpty, !rule.replacement.isEmpty else {
                throw TincallError(message: String(localized: "请填写每条纠错规则的错词和正确词，或删除空白规则。"))
            }
            guard sources.insert(rule.source).inserted else {
                throw TincallError(message: String(localized: "同一个错词只能添加一条规则，请合并重复项。"))
            }
            guard ids.insert(rule.id).inserted else {
                throw TincallError(message: String(localized: "纠错规则标识重复，请删除重复项后重试。"))
            }
            return rule
        }
    }

    /// Reuse existing provider configuration; selecting a service never creates another preset.
    func selectSTTProvider(_ provider: ConnectionProvider?) throws {
        guard let provider else {
            var next = roles
            for index in next.indices { next[index].sttConnectionID = nil }
            try persist(connections: connections, roles: next, retention: retention, defaultSTTConnectionID: nil)
            return
        }
        guard provider.isSpeechRecognition else { throw TincallError(message: String(localized: "请选择语音识别服务")) }
        let current = connections.first { $0.id == defaultSTTConnectionID && $0.provider == provider }
        if let saved = current ?? connections.first(where: { $0.provider == provider }) {
            try saveDefaultSTTConnection(saved.id)
            return
        }
        let name: String
        switch provider {
        case .appleSpeech: name = String(localized: "Apple 本机识别")
        case .xunfei: name = String(localized: "讯飞")
        case .bailian: name = String(localized: "百炼")
        case .whisperCompatible: name = String(localized: "Whisper 兼容")
        default: throw TincallError(message: String(localized: "请选择语音识别服务"))
        }
        var value = ConnectionProfile(name: name, provider: provider)
        if provider == .appleSpeech { value.language = "zh-CN" }
        if provider == .bailian { value.model = "paraformer-realtime-v2"; value.region = "beijing" }
        if provider == .whisperCompatible {
            value.endpoint = URL(string: "https://api.openai.com/v1")
            value.model = "whisper-1"
        }
        try persist(connections: connections + [value], roles: roles, retention: retention,
                    defaultSTTConnectionID: value.id)
    }

    func refreshLinkedContacts() async {
        if isRefreshingContacts { refreshContactsAgain = true; return }
        isRefreshingContacts = true
        defer { isRefreshingContacts = false }
        repeat {
            refreshContactsAgain = false
            var next = roles
            var usedNumbers = Set(roles.compactMap(\.systemCallPhoneNumber))
            for index in next.indices where next[index].linkedContact != nil && next[index].systemCallPhoneNumber == nil {
                let number = SystemCallContact.newPhoneNumber(excluding: usedNumbers)
                next[index].systemCallPhoneNumber = number
                usedNumbers.insert(number)
            }
            do {
                if next != roles {
                    try persist(connections: connections, roles: next, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID)
                }
            } catch {
                contactSyncIssue = String(localized: "联系人更新未保存，原资料已保留，请重试。")
                return
            }
            let expectedLinks = Dictionary(uniqueKeysWithValues: roles.compactMap { role in
                role.linkedContact.map { (role.id, $0.identifier) }
            })
            var snapshots: [String: LinkedContact] = [:]
            var failures: [String: String] = [:]
            for identifier in Set(expectedLinks.values) {
                let numbers = Dictionary(uniqueKeysWithValues: roles.compactMap { role -> (UUID, String)? in
                    guard expectedLinks[role.id] == identifier, let number = role.systemCallPhoneNumber else { return nil }
                    return (role.id, number)
                })
                do { snapshots[identifier] = try await contactReader.read(identifier: identifier, callNumbers: numbers) }
                catch { failures[identifier] = error.localizedDescription }
            }
            let relevantFailures = failures.filter { identifier, _ in
                roles.contains { expectedLinks[$0.id] == identifier && $0.linkedContact?.identifier == identifier }
            }
            do {
                try mergeLinkedContacts(snapshots, expectedLinks: expectedLinks)
                contactSyncIssues = Dictionary(uniqueKeysWithValues: roles.compactMap { role in
                    guard let identifier = role.linkedContact?.identifier,
                          let failure = relevantFailures[identifier] else { return nil }
                    return (role.id, failure)
                })
                contactSyncIssue = relevantFailures.isEmpty ? nil : String(localized: "关联联系人未全部更新，已保留上次资料。\n\(relevantFailures.values.first ?? String(localized: "请检查通讯录权限或重新选择联系人。"))")
            } catch {
                contactSyncIssue = String(localized: "关联联系人更新未保存，已保留原资料。请重试。")
                contactSyncIssues = Dictionary(uniqueKeysWithValues: roles.filter { expectedLinks[$0.id] != nil }.map {
                    ($0.id, String(localized: "联系人更新未保存，原资料已保留，请重试。"))
                })
            }
        } while refreshContactsAgain
    }

    /// Merge read results into current roles, preserving edits made while the reader was awaited.
    func mergeLinkedContacts(_ snapshots: [String: LinkedContact], expectedLinks: [UUID: String]) throws {
        var next = roles
        for index in next.indices {
            guard let identifier = expectedLinks[next[index].id],
                  next[index].linkedContact?.identifier == identifier,
                  let snapshot = snapshots[identifier], snapshot.identifier == identifier else { continue }
            next[index].linkedContact = snapshot
        }
        guard next != roles else { return }
        try persist(connections: connections, roles: next, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID)
    }

    struct ImportPlan {
        let configuration: Configuration
        let roleIDs: [UUID: UUID]
        let connectionIDs: [UUID: UUID]
        let addedConnections: Int
        let addedRoles: Int
    }

    func backupConfiguration() -> Configuration {
        Configuration(connections: connections, roles: roles, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID,
                      userProfile: userProfile, speechRecognitionCorrections: speechRecognitionCorrections)
    }

    func storageBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw TincallError(message: String(localized: "无法读取本机配置文件大小。"))
        }
        return Int64(size)
    }

    /// Merge portable public configuration. Existing IDs and their Keychain items are never overwritten.
    func prepareImport(_ imported: Configuration) throws -> ImportPlan {
        var imported = imported
        _ = imported.migrateExternalIdentities()
        guard Set(imported.connections.map(\.id)).count == imported.connections.count,
              Set(imported.roles.map(\.id)).count == imported.roles.count else {
            throw TincallError(message: String(localized: "备份包含重复的连接或联系人标识"))
        }
        for connection in imported.connections {
            guard !connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TincallError(message: String(localized: "备份连接名称为空"))
            }
            if connection.provider.isLanguageModel || connection.provider == .genericConnector || connection.provider == .whisperCompatible {
                guard let url = connection.endpoint, url.scheme == "https", url.host?.isEmpty == false,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                    throw TincallError(message: String(localized: "备份的请求地址无效或包含内嵌凭据"))
                }
            } else if connection.endpoint != nil {
                throw TincallError(message: String(localized: "备份的语音连接应使用固定供应商地址"))
            }
        }
        for role in imported.roles { try validateRole(role, connections: imported.connections) }
        if let id = imported.defaultSTTConnectionID,
           !imported.connections.contains(where: { $0.id == id && $0.provider.isSpeechRecognition }) {
            throw TincallError(message: String(localized: "备份的默认识别服务无效"))
        }
        var merged = backupConfiguration()
        var corrections = speechRecognitionCorrections
        for var rule in try validatedCorrections(imported.speechRecognitionCorrections ?? []) {
            // Keep the local correction when both configurations contain the same source phrase.
            guard !corrections.contains(where: { $0.source == rule.source }) else { continue }
            while corrections.contains(where: { $0.id == rule.id }) { rule.id = UUID() }
            corrections.append(rule)
        }
        merged.speechRecognitionCorrections = corrections
        var connectionIDs: [UUID: UUID] = [:]
        for var connection in imported.connections {
            let sourceID = connection.id
            if let existing = merged.connections.first(where: { $0.id == sourceID }) {
                if existing == connection { connectionIDs[sourceID] = sourceID; continue }
                repeat { connection.id = UUID() } while merged.connections.contains { $0.id == connection.id }
            }
            connectionIDs[sourceID] = connection.id
            merged.connections.append(connection)
        }
        var roleIDs: [UUID: UUID] = [:]
        for var role in imported.roles {
            let sourceID = role.id
            role.modelConnectionID = role.modelConnectionID.flatMap { connectionIDs[$0] }
            role.summaryConnectionID = role.summaryConnectionID.flatMap { connectionIDs[$0] }
            role.sttConnectionID = role.sttConnectionID.flatMap { connectionIDs[$0] }
            role.ttsConnectionID = role.ttsConnectionID.flatMap { connectionIDs[$0] }
            role.externalConnectionID = role.externalConnectionID.flatMap { connectionIDs[$0] }
            if let existing = merged.roles.first(where: { $0.id == sourceID }) {
                if existing == role { roleIDs[sourceID] = sourceID; continue }
                repeat { role.id = UUID() } while merged.roles.contains { $0.id == role.id }
            }
            roleIDs[sourceID] = role.id
            merged.roles.append(role)
        }
        if connections.isEmpty && roles.isEmpty {
            merged.retention = imported.retention
            if userProfile == LocalUserProfile() { merged.userProfile = imported.userProfile }
        }
        if merged.defaultSTTConnectionID == nil {
            merged.defaultSTTConnectionID = imported.defaultSTTConnectionID.flatMap { connectionIDs[$0] }
        }
        return ImportPlan(configuration: merged, roleIDs: roleIDs, connectionIDs: connectionIDs,
                          addedConnections: merged.connections.count - connections.count,
                          addedRoles: merged.roles.count - roles.count)
    }

    func commitImport(_ plan: ImportPlan) throws {
        let value = plan.configuration
        try persist(connections: value.connections, roles: value.roles, retention: value.retention,
                    defaultSTTConnectionID: value.defaultSTTConnectionID, userProfile: value.userProfile,
                    speechRecognitionCorrections: value.speechRecognitionCorrections)
    }

    private func validateRole(_ role: CallRole, connections: [ConnectionProfile]) throws {
        guard !role.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TincallError(message: String(localized: "请填写联系人姓名")) }
        if let id = role.modelConnectionID, !connections.contains(where: { $0.id == id && $0.provider.isLanguageModel }) { throw TincallError(message: String(localized: "请选择有效的模型连接")) }
        if let id = role.summaryConnectionID, !connections.contains(where: { $0.id == id && $0.provider.isLanguageModel }) { throw TincallError(message: String(localized: "请选择有效的摘要模型连接")) }
        if let id = role.sttConnectionID, !connections.contains(where: { $0.id == id && $0.provider.isSpeechRecognition }) { throw TincallError(message: String(localized: "请选择有效的识别连接")) }
        if let id = role.externalConnectionID, !connections.contains(where: { $0.id == id && $0.provider == .genericConnector }) { throw TincallError(message: String(localized: "请选择有效的外部连接")) }
        if let id = role.ttsConnectionID, !connections.contains(where: { $0.id == id && $0.provider.isSpeechSynthesis }) { throw TincallError(message: String(localized: "请选择有效的语音连接")) }
    }

    private func persist(connections: [ConnectionProfile], roles: [CallRole], retention: AudioRetention, defaultSTTConnectionID: UUID?, userProfile: LocalUserProfile? = nil,
                         speechRecognitionCorrections: [SpeechRecognitionCorrection]? = nil) throws {
        let userProfile = userProfile ?? self.userProfile
        let corrections = speechRecognitionCorrections ?? self.speechRecognitionCorrections
        let data = try JSONEncoder().encode(Configuration(connections: connections, roles: roles, retention: retention, defaultSTTConnectionID: defaultSTTConnectionID,
                                                        userProfile: userProfile, speechRecognitionCorrections: corrections))
        try data.write(to: fileURL, options: .atomic)
        self.connections = connections
        contactSyncIssues = contactSyncIssues.filter { id, _ in
            roles.contains {
                $0.id == id && $0.linkedContact != nil
                    && $0.linkedContact?.identifier == self.roles.first(where: { $0.id == id })?.linkedContact?.identifier
            }
        }
        self.roles = roles
        self.retention = retention
        self.defaultSTTConnectionID = defaultSTTConnectionID
        self.userProfile = userProfile
        self.speechRecognitionCorrections = corrections
    }
}
