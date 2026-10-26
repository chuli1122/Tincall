// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

/// Owns cloud setup and its cached credentials; the editor remains the owner of the draft.
@MainActor
@Observable
final class RoleMCPSetup {
    private(set) var configuration: MCPRoleConfiguration?
    private(set) var manualDirectory: ExternalContactDirectory?
    private(set) var isLoadingWakeConfiguration = false
    private(set) var wakeIssue: String?
    private var wakeConfiguration: WakeBridgeConfiguration?
    private var wakeConnection: ConnectionProfile?
    private var wakeContactID: String?
    private var wakeLoadID: UUID?
    private var revision = UUID()
    private let client: ExternalCallClient
    private let credentials: CredentialStore

    init(client: ExternalCallClient = ExternalCallClient(), credentials: CredentialStore = CredentialStore()) {
        self.client = client
        self.credentials = credentials
    }

    func invalidate() {
        revision = UUID()
        wakeLoadID = nil
        isLoadingWakeConfiguration = false
    }

    func resetConnection() {
        invalidate()
        configuration = nil
        manualDirectory = nil
        wakeConfiguration = nil
        wakeConnection = nil
        wakeContactID = nil
        wakeIssue = nil
    }

    func loadSaved(role: CallRole, connection: ConnectionProfile?) throws -> MCPRoleConfiguration? {
        configuration = nil
        guard let connection,
              let saved = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: role.id),
              saved.mcp_url == connection.mcpURL,
              role.externalRoleID == nil || saved.contact_id == role.externalRoleID else { return nil }
        try saved.validate(connection: connection, contactID: saved.contact_id)
        configuration = saved
        return saved
    }

    func canReuse(role: CallRole, connection: ConnectionProfile?) -> Bool {
        guard let connection, connection.provider == .genericConnector, let configuration else { return false }
        return configuration.mcp_url == connection.mcpURL
            && configuration.mcp_wait_timeout_seconds == role.effectiveMCPWaitTimeoutSeconds
            && configuration.contact_id == role.mcpContactID
            && configuration.display_name == role.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func savedWakeConfiguration(connection: ConnectionProfile, contactID: String) -> WakeBridgeConfiguration? {
        guard wakeConnection == connection, wakeContactID == contactID else { return nil }
        return wakeConfiguration
    }

    func loadWakeConfiguration(connection: ConnectionProfile, contactID: String, role: CallRole? = nil) async {
        let loadID = UUID()
        wakeLoadID = loadID
        isLoadingWakeConfiguration = true
        wakeIssue = nil
        defer { if wakeLoadID == loadID { isLoadingWakeConfiguration = false } }
        func checkLoad() throws {
            try Task.checkCancellation()
            guard wakeLoadID == loadID else { throw CancellationError() }
        }
        do {
            let value: WakeBridgeConfiguration
            do {
                value = try await client.wakeBridgeConfiguration(connection: connection, contactID: contactID)
            } catch let failure as ExternalCallFailure where failure.code == "contact_not_found" {
                try checkLoad()
                guard let role, role.effectiveCallMode == .mcp,
                      role.externalConnectionID == connection.id, role.mcpContactID == contactID else { throw failure }
                let registered = try await client.upsertMCPRole(connection: connection, role: role)
                try checkLoad()
                try await client.setMCPContactMode(connection: connection, roleID: role.id, mode: .mcp)
                try checkLoad()
                try credentials.writeMCPConfiguration(registered, connectionID: connection.id, roleID: role.id)
                configuration = registered
                value = try await client.wakeBridgeConfiguration(connection: connection, contactID: contactID)
            }
            try checkLoad()
            guard value.version == 2 else {
                throw TincallError(message: String(localized: "请先更新此服务，再复制带有专用 MCP 的唤醒桥配置。"))
            }
            wakeConfiguration = value
            wakeConnection = connection
            wakeContactID = contactID
        } catch {
            guard !Task.isCancelled, wakeLoadID == loadID else { return }
            if let failure = error as? ExternalCallFailure, failure.code == "contact_not_found" {
                wakeIssue = String(localized: "云端未找到这位联系人的 MCP 身份。请确认所选云端连接，并重新获取 MCP 配置。")
            } else {
                wakeIssue = error.localizedDescription
            }
        }
    }

    /// Publish local success only after the cloud and credential writes succeed.
    /// Invalidating the editor prevents late responses from saving a discarded draft.
    func save(role: CallRole, previous: CallRole, store: LocalConfigurationStore) async throws -> CallRole {
        let requestRevision = revision
        do {
            var next = role
            if next.effectiveCallMode != .mcp {
                do {
                    guard let connection = store.connections.first(where: { $0.id == previous.externalConnectionID }),
                          let saved = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: next.id),
                          saved.mcp_url == connection.mcpURL else {
                        throw TincallError(message: String(localized: "原 MCP 连接已更改，请恢复原连接后再切换模式。"))
                    }
                    try await client.setMCPContactMode(connection: connection, roleID: next.id, mode: next.effectiveCallMode)
                    try checkRequest(requestRevision)
                    try store.saveRole(next)
                    return next
                } catch is CancellationError { throw CancellationError() }
                catch {
                    throw TincallError(message: (error as? TincallError)?.message
                        ?? String(localized: "联系人模式未同步到云端，设置未保存，请重试。"))
                }
            }
            guard let connection = store.connections.first(where: { $0.id == next.externalConnectionID && $0.provider == .genericConnector }) else {
                throw TincallError(message: String(localized: "请选择有效的 Tincall 云端连接。"))
            }
            let directory = try await client.contactDirectory(connection: connection)
            try checkRequest(requestRevision)
            guard directory.mcp_role_management == true else {
                manualDirectory = directory
                throw TincallError(message: String(localized: "此服务不支持自动配置 MCP。请在下方按手动接入说明完成配置。"))
            }
            let configured = try await client.upsertMCPRole(connection: connection, role: next)
            try checkRequest(requestRevision)
            try await client.setMCPContactMode(connection: connection, roleID: next.id, mode: .mcp)
            try checkRequest(requestRevision)
            next.externalRoleID = configured.contact_id
            next.externalRoleName = configured.display_name
            try credentials.writeMCPConfiguration(configured, connectionID: connection.id, roleID: next.id)
            try store.saveRole(next)
            configuration = configured
            manualDirectory = nil
            return next
        } catch {
            try checkRequest(requestRevision)
            throw error
        }
    }

    private func checkRequest(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
    }
}
