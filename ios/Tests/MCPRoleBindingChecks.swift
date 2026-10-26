// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class RoleProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var status = 200
        var wrongToken = false
        var path = "mcp"
        var wrongRole = false
        var waitResponse = "requested"
        var requests: [[String: Any]] = []
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.path == "/tincall/mcp/roles/upsert", request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-phone-token" else {
                throw TincallError(message: "Unexpected request route or phone authorization")
            }
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw TincallError(message: "Fixture body stream failed") }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let roleID = payload["role_id"] as! String
            let state = Self.fixture.lock.withLock {
                Self.fixture.requests.append(payload)
                return (Self.fixture.status, Self.fixture.wrongToken, Self.fixture.path, Self.fixture.wrongRole, Self.fixture.waitResponse)
            }
            let data: Data
            if state.0 != 200 {
                data = Data(#"{"error":{"code":"forbidden"}}"#.utf8)
            } else {
                var result: [String: Any] = ["role_id": state.3 ? UUID().uuidString : payload["role_id"]!, "contact_id": payload["contact_id"]!,
                    "display_name": payload["display_name"]!, "mcp_path": state.2, "token_created": false,
                    "token": state.1 ? "synthetic-phone-token" : "synthetic-role-token-\(roleID)"]
                if state.4 != "missing" { result["mcp_wait_timeout_seconds"] = state.4 == "wrong" ? 130 : payload["mcp_wait_timeout_seconds"]! }
                data = try JSONSerialization.data(withJSONObject: result)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: state.0, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main
struct MCPRoleBindingChecks {
    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        var connection = ConnectionProfile(name: "Synthetic service", provider: .genericConnector,
            endpoint: URL(string: "https://mcp-fixture.invalid/tincall"))
        connection.externalRoleID = "shared-default-must-not-be-used"
        DataSharingConsent.setAllowed(true, for: connection)
        defer { UserDefaults.standard.removeObject(forKey: "tincall.dataSharing.v1.\(connection.id.uuidString)") }
        var role = CallRole(name: "Synthetic role", callMode: .mcp, externalConnectionID: connection.id)
        let otherRole = CallRole(name: "Another role", callMode: .mcp, externalConnectionID: connection.id)
        let otherConnectionID = UUID()
        defer {
            try? credentials.delete(connectionID: connection.id)
            try? credentials.deleteMCPConfiguration(connectionID: connection.id, roleID: role.id)
            try? credentials.deleteMCPConfiguration(connectionID: connection.id, roleID: otherRole.id)
            try? credentials.deleteMCPConfiguration(connectionID: otherConnectionID, roleID: role.id)
        }
        try credentials.write("synthetic-phone-token", connectionID: connection.id)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RoleProtocol.self]
        let client = ExternalCallClient(configuration: sessionConfiguration)
        let first = try await client.upsertMCPRole(connection: connection, role: role)
        role.externalRoleID = first.contact_id
        role.externalRoleName = first.display_name
        role.name = "Renamed role"
        role.mcpWaitTimeoutSeconds = 100
        let repeated = try await client.upsertMCPRole(connection: connection, role: role)
        let another = try await client.upsertMCPRole(connection: connection, role: otherRole)
        precondition(first.token == repeated.token && first.contact_id == repeated.contact_id)
        precondition(another.contact_id != first.contact_id && another.token != first.token)
        let requests = RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.requests }
        precondition(requests[0]["role_id"] as? String == role.id.uuidString.lowercased())
        precondition(requests[0]["contact_id"] as? String == role.id.uuidString.lowercased())
        precondition(requests[1]["display_name"] as? String == "Renamed role")
        precondition(requests[0]["mcp_wait_timeout_seconds"] as? Int == 120)
        precondition(requests[1]["mcp_wait_timeout_seconds"] as? Int == 100)
        precondition(first.mcp_wait_timeout_seconds == 120 && repeated.mcp_wait_timeout_seconds == 100)
        for response in ["missing", "wrong"] {
            RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.waitResponse = response }
            do { _ = try await client.upsertMCPRole(connection: connection, role: role); preconditionFailure("Unconfirmed wait setting accepted") }
            catch is TincallError { }
        }
        RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.waitResponse = "requested" }
        try credentials.writeMCPConfiguration(repeated, connectionID: connection.id, roleID: role.id)
        try credentials.writeMCPConfiguration(another, connectionID: connection.id, roleID: otherRole.id)
        try credentials.writeMCPConfiguration(another, connectionID: otherConnectionID, roleID: role.id)
        let reopened = try CredentialStore().readMCPConfiguration(connectionID: connection.id, roleID: role.id)
        precondition(reopened == repeated)
        let phone = try credentials.read(connectionID: connection.id)
        precondition(phone == "synthetic-phone-token")
        try credentials.deleteMCPConfiguration(connectionID: connection.id, roleID: role.id)
        let removed = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: role.id)
        let otherRoleSaved = try credentials.readMCPConfiguration(connectionID: connection.id, roleID: otherRole.id)
        let otherConnectionSaved = try credentials.readMCPConfiguration(connectionID: otherConnectionID, roleID: role.id)
        precondition(removed == nil && otherRoleSaved == another && otherConnectionSaved == another)
        let publicJSON = String(decoding: try JSONEncoder().encode(role), as: UTF8.self)
        precondition(!publicJSON.contains(first.token) && !publicJSON.contains("synthetic-phone-token"))
        let export = try JSONSerialization.jsonObject(with: Data(repeated.platformConfigurationJSON().utf8)) as! [String: Any]
        let servers = export["mcpServers"] as! [String: [String: Any]]
        let exported = servers["tincall-\(repeated.contact_id)"]!
        precondition(exported["url"] as? String == repeated.mcp_url.absoluteString)
        precondition((exported["headers"] as? [String: String])?["Authorization"] == "Bearer \(repeated.token)")
        var wrongConnection = connection
        wrongConnection.endpoint = URL(string: "https://another-fixture.invalid/tincall")
        do { try repeated.validate(connection: wrongConnection, contactID: role.mcpContactID); preconditionFailure("Wrong service accepted") }
        catch is TincallError { }
        do { try repeated.validate(connection: connection, contactID: "wrong-role"); preconditionFailure("Wrong identity accepted") }
        catch is TincallError { }
        RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.status = 403 }
        do { _ = try await client.upsertMCPRole(connection: connection, role: role); preconditionFailure("Forbidden response accepted") }
        catch let error as ExternalCallFailure { precondition(error.status == 403) }
        RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.status = 200; RoleProtocol.fixture.wrongToken = true }
        do { _ = try await client.upsertMCPRole(connection: connection, role: role); preconditionFailure("Phone token accepted as role token") }
        catch is TincallError { }
        RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.wrongToken = false; RoleProtocol.fixture.path = "../untrusted" }
        do { _ = try await client.upsertMCPRole(connection: connection, role: role); preconditionFailure("Untrusted MCP path accepted") }
        catch is TincallError { }
        RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.path = "mcp"; RoleProtocol.fixture.wrongRole = true }
        do { _ = try await client.upsertMCPRole(connection: connection, role: role); preconditionFailure("Another local role accepted") }
        catch is TincallError { }
        let requestCount = RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.requests.count }
        role.name = String(repeating: "a", count: 201)
        do { _ = try await client.upsertMCPRole(connection: connection, role: role); preconditionFailure("Oversize name submitted") }
        catch is TincallError { }
        precondition(RoleProtocol.fixture.lock.withLock { RoleProtocol.fixture.requests.count } == requestCount)
        print("PASS: real client request contract, stable roles, Keychain isolation/reopen/delete, secret-free public JSON, MCP export, invalid responses and errors")
    }
}
