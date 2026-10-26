// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class SetupProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var automatic = true
        var heldPath: String?
        var pending: (SetupProtocol, Data)?
        var modeWrites = 0
        var wakeNeedsRegistration = false
        var registeredRoles: [(String, String)] = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-setup.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let input = body.isEmpty ? [:] : try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let path = request.url!.path
            let output: [String: Any]
            switch path {
            case "/tincall/capabilities":
                output = ["mcp_role_management": Self.fixture.lock.withLock { Self.fixture.automatic },
                          "bindings": [["contact_id": "manual", "display_name": "Manual contact", "generation_configured": true, "mode": "tools"]]]
            case "/tincall/mcp/roles/upsert":
                Self.fixture.lock.withLock {
                    Self.fixture.registeredRoles.append((input["role_id"] as! String, input["contact_id"] as! String))
                }
                output = ["role_id": input["role_id"]!, "contact_id": input["contact_id"]!, "display_name": input["display_name"]!,
                          "mcp_path": "mcp", "token": "synthetic-role-token", "token_created": false,
                          "mcp_wait_timeout_seconds": input["mcp_wait_timeout_seconds"]!]
            case "/tincall/mcp/roles/mode":
                Self.fixture.lock.withLock {
                    Self.fixture.modeWrites += 1
                    if input["call_mode"] as? String == "mcp" { Self.fixture.wakeNeedsRegistration = false }
                }
                output = ["call_mode": input["call_mode"]!]
            case "/tincall/wake/config":
                if Self.fixture.lock.withLock({ Self.fixture.wakeNeedsRegistration }) {
                    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404,
                        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(#"{"error":{"code":"contact_not_found"}}"#.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                let headers = ["Authorization": "Bearer tcwake_" + String(repeating: "a", count: 64)]
                let base = "https://mcp-setup.invalid/tincall/"
                output = ["version": 2, "contact_id": input["contact_id"]!, "instructions": "Synthetic setup",
                          "wake": ["transport": "sse", "url": base + "wake/events", "event": "wake", "headers": headers],
                          "input": ["transport": "http", "url": base + "wake/input", "headers": headers],
                          "mcp": ["transport": "streamable-http", "url": base + "mcp/wake", "headers": headers]]
            default: preconditionFailure("Unexpected synthetic setup route")
            }
            let data = try JSONSerialization.data(withJSONObject: output)
            let held = Self.fixture.lock.withLock {
                guard Self.fixture.heldPath == path else { return false }
                Self.fixture.heldPath = nil
                Self.fixture.pending = (self, data)
                return true
            }
            if !held { complete(data) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func complete(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func release() {
        let held = fixture.lock.withLock { let value = fixture.pending; fixture.pending = nil; return value }
        precondition(held != nil)
        held!.0.complete(held!.1)
    }
    override func stopLoading() { }
}

@main struct RoleMCPSetupChecks {
    @MainActor static func waitForHeldRequest() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !SetupProtocol.fixture.lock.withLock({ SetupProtocol.fixture.pending != nil }) {
            precondition(Date() < deadline, "Setup request timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TincallMCPSetup-\(UUID())")
        let store = try LocalConfigurationStore(directory: root)
        let credentials = CredentialStore()
        let connection = ConnectionProfile(name: "Synthetic service", provider: .genericConnector,
            endpoint: URL(string: "https://mcp-setup.invalid/tincall"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        let role = CallRole(name: "Synthetic contact", callMode: .mcp, externalConnectionID: connection.id)
        try store.saveConnection(connection)
        try credentials.write("synthetic-phone-token", connectionID: connection.id)
        defer {
            try? credentials.delete(connectionID: connection.id)
            try? credentials.deleteMCPConfiguration(connectionID: connection.id, roleID: role.id)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SetupProtocol.self]
        let client = ExternalCallClient(configuration: configuration, logs: RequestLogStore(directory: root.appendingPathComponent("logs")))
        let setup = RoleMCPSetup(client: client, credentials: credentials)
        let saved = try await setup.save(role: role, previous: role, store: store)
        precondition(store.roles == [saved] && setup.canReuse(role: saved, connection: connection))
        let storedCredential = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: role.id)
        precondition(storedCredential == setup.configuration)
        var changedAddress = connection
        changedAddress.endpoint = URL(string: "https://changed.invalid/tincall")
        let wrongAddress = try setup.loadSaved(role: saved, connection: changedAddress)
        precondition(wrongAddress == nil && setup.configuration == nil)
        let reopened = try setup.loadSaved(role: saved, connection: connection)
        precondition(reopened != nil)
        print("PASS: cloud identity saves through the real credential/store path; a changed address cannot reuse its credential")

        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.heldPath = "/tincall/wake/config" }
        let oldLoad = Task { await setup.loadWakeConfiguration(connection: connection, contactID: "old") }
        try await waitForHeldRequest()
        setup.resetConnection()
        await setup.loadWakeConfiguration(connection: connection, contactID: "new")
        SetupProtocol.release()
        await oldLoad.value
        precondition(setup.savedWakeConfiguration(connection: connection, contactID: "new")?.contact_id == "new")
        precondition(setup.savedWakeConfiguration(connection: connection, contactID: "old") == nil)
        precondition(!setup.isLoadingWakeConfiguration && setup.wakeIssue == nil)
        print("PASS: a late wake configuration cannot replace the newly selected contact")

        let registeredBeforeRecovery = SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.registeredRoles.count }
        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.wakeNeedsRegistration = true }
        await setup.loadWakeConfiguration(connection: connection, contactID: saved.mcpContactID, role: saved)
        precondition(setup.savedWakeConfiguration(connection: connection, contactID: saved.mcpContactID) != nil,
                     "An existing ordinary MCP identity must recover its wake configuration")
        precondition(setup.wakeIssue == nil)
        let registered = SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.registeredRoles }
        precondition(registered.count == registeredBeforeRecovery + 1)
        precondition(registered.last!.0 == saved.id.uuidString.lowercased() && registered.last!.1 == saved.mcpContactID,
                     "Recovery must keep the same role and contact IDs")
        let recoveredCredential = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: role.id)
        precondition(recoveredCredential?.token == storedCredential?.token)
        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.wakeNeedsRegistration = true }
        await setup.loadWakeConfiguration(connection: connection, contactID: "unsaved")
        precondition(setup.wakeIssue != nil)
        precondition(SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.registeredRoles.count } == registered.count,
                     "Reading a draft must not create a cloud identity")
        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.wakeNeedsRegistration = false }
        print("PASS: wake setup repairs the saved MCP identity without changing its IDs or token; drafts stay unregistered")

        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.heldPath = "/tincall/mcp/roles/upsert" }
        var edited = saved
        edited.name = "Unsaved edit"
        let modeWrites = SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.modeWrites }
        let saving = Task { try await setup.save(role: edited, previous: saved, store: store) }
        try await waitForHeldRequest()
        setup.invalidate()
        SetupProtocol.release()
        do { _ = try await saving.value; preconditionFailure("Discarded edit was saved") }
        catch is CancellationError { }
        precondition(store.roles == [saved])
        precondition(SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.modeWrites } == modeWrites)
        print("PASS: closing during setup prevents the late result from changing cloud mode or saving a discarded draft")

        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.automatic = false }
        do { _ = try await setup.save(role: edited, previous: saved, store: store); preconditionFailure("Manual setup accepted as automatic") }
        catch is TincallError { }
        precondition(setup.manualDirectory?.contacts.first?.id == "manual" && store.roles == [saved])
        SetupProtocol.fixture.lock.withLock { SetupProtocol.fixture.automatic = true }
        var standalone = saved
        standalone.callMode = .standalone
        let switched = try await setup.save(role: standalone, previous: saved, store: store)
        precondition(switched.effectiveCallMode == .standalone && store.roles == [switched])
        print("PASS: manual setup preserves the draft; leaving MCP synchronizes the contact mode before saving")
    }
}
