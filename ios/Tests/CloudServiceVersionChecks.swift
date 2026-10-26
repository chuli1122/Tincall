// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class VersionProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var body = #"{"version":1,"bindings":[]}"#
        var status = 200
        var networkFailure = false
        var paths: [String] = []
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "version-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.httpMethod == "GET" && request.httpBody == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-phone-token")
        let state = Self.fixture.lock.withLock {
            Self.fixture.paths.append(request.url!.path)
            return (Self.fixture.body, Self.fixture.status, Self.fixture.networkFailure)
        }
        if state.2 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: state.1, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type":"application/json", "Cache-Control":"no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(state.0.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct CloudServiceVersionChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = CloudDeploymentResources(root: root)
        let revision = try CloudServiceVersion.required(resources: resources)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tincall-version-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let credentials = CredentialStore()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [VersionProtocol.self]
        let client = ExternalCallClient(credentials: credentials, configuration: session,
            logs: RequestLogStore(directory: temporary.appendingPathComponent("logs")))
        let check = CloudServiceVersionCheck(client: client, resources: resources)
        var connection = ConnectionProfile(name: "Synthetic service", provider: .genericConnector,
            endpoint: URL(string: "https://version-fixture.invalid"))
        try credentials.write("synthetic-phone-token", connectionID: connection.id)
        defer {
            try? credentials.delete(connectionID: connection.id)
            UserDefaults.standard.removeObject(forKey: "tincall.dataSharing.v1.\(connection.id.uuidString)")
            UserDefaults.standard.removeObject(forKey: "tincall.dataSharing.v1.\(connection.id.uuidString).revoked")
        }
        DataSharingConsent.setAllowed(true, for: connection)

        func reply(revision: Int?) {
            VersionProtocol.fixture.lock.withLock {
                VersionProtocol.fixture.body = revision.map { "{\"version\":1,\"server_version\":\($0),\"bindings\":[]}" }
                    ?? #"{"version":1,"bindings":[]}"#
                VersionProtocol.fixture.status = 200
                VersionProtocol.fixture.networkFailure = false
            }
        }
        func requireUnavailable() {
            guard case .unavailable = check.status else { preconditionFailure("A failed check must not claim an outdated service") }
        }

        for path in ["", "/tincall", "/functions/v1/tincall"] {
            connection.endpoint = URL(string: "https://version-fixture.invalid" + path)
            DataSharingConsent.setAllowed(true, for: connection)
            reply(revision: nil)
            await check.refresh(connection: connection)
            precondition(check.status == .updateRequired(nil), "Legacy services without a revision require redeployment")
            reply(revision: revision - 1)
            await check.refresh(connection: connection)
            precondition(check.status == .updateRequired(revision - 1))
            reply(revision: revision)
            await check.refresh(connection: connection)
            precondition(check.status == .current(revision), "A successful refresh must clear the old deployment warning")
            reply(revision: revision + 1)
            await check.refresh(connection: connection)
            precondition(check.status == .current(revision + 1), "Newer deployments stay compatible")
            precondition(VersionProtocol.fixture.lock.withLock { VersionProtocol.fixture.paths.last } == path + "/capabilities")
        }
        print("PASS: manual/Supabase routes, missing/old/current/new revisions and refreshed warning removal")

        reply(revision: nil)
        await check.refresh(connection: connection)
        for status in [401, 404, 503] {
            VersionProtocol.fixture.lock.withLock {
                VersionProtocol.fixture.status = status
                VersionProtocol.fixture.body = #"{"error":{"code":"service_unavailable"}}"#
            }
            await check.refresh(connection: connection)
            requireUnavailable()
        }
        reply(revision: nil)
        VersionProtocol.fixture.lock.withLock { VersionProtocol.fixture.networkFailure = true }
        await check.refresh(connection: connection)
        requireUnavailable()
        reply(revision: revision)
        await check.refresh(connection: connection)
        precondition(check.status == .current(revision))
        let requestCount = VersionProtocol.fixture.lock.withLock { VersionProtocol.fixture.paths.count }
        DataSharingConsent.setAllowed(false, for: connection)
        await check.refresh(connection: connection)
        requireUnavailable()
        precondition(VersionProtocol.fixture.lock.withLock { VersionProtocol.fixture.paths.count } == requestCount,
            "Version checks must obey the existing destination consent")
        print("PASS: authorization/404/server/offline errors stay distinct from outdated state; destination consent prevents requests")

        DataSharingConsent.setAllowed(true, for: connection)
        let missing = CloudServiceVersionCheck(client: client, resources: CloudDeploymentResources(root: temporary))
        await missing.refresh(connection: connection)
        guard case .unavailable = missing.status else { preconditionFailure("Missing bundled resources must be reported") }
        precondition(VersionProtocol.fixture.lock.withLock { VersionProtocol.fixture.paths.count } == requestCount)
        print("PASS: required version comes from bundled deployment resources; missing resources do not trigger a request")
    }
}
