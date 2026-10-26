// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class PaginationProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        let owner = UUID()
        let record = UUID()
        var timestamp = "2030-01-01T00:00:00+00:00"
        var reads = 0
        var backupOnlyDeletion = false
        var deletions = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pagination-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-pagination-token")
        let (status, payload): (Int, [String: Any]) = Self.fixture.lock.withLock {
            let f = Self.fixture
            if url.path == "/capabilities" { return (200, ["owner_id": f.owner.uuidString, "backup_only_deletion": f.backupOnlyDeletion]) }
            if request.httpMethod == "POST" {
                precondition(url.path.lowercased() == "/records/\(f.record.uuidString.lowercased())/delete-backup")
                f.deletions += 1
                return (200, ["record": ["id": f.record.uuidString, "revision": 2, "deleted": true, "updated_at": f.timestamp]])
            }
            precondition(url.path == "/records" && request.httpMethod == "GET")
            f.reads += 1
            // WHATWG URLSearchParams on the real connector uses form decoding:
            // a literal plus means a space; only %2B survives as a timezone sign.
            let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery ?? ""
            let fields = encoded.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
            let query = Dictionary(uniqueKeysWithValues: fields.map {
                (String($0[0]), String($0[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!)
            })
            if query.isEmpty {
                return (200, ["records": [["id": f.record.uuidString, "revision": 1, "deleted": false, "updated_at": f.timestamp]],
                              "next_cursor": ["after": f.timestamp, "after_id": f.record.uuidString]])
            }
            guard query["after"] == f.timestamp, query["after_id"] == f.record.uuidString else {
                return (400, ["error": ["code": "database_request_failed"]])
            }
            return (200, ["records": [], "next_cursor": NSNull()])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct CloudSyncPaginationChecks {
    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let connection = ConnectionProfile(name: "Synthetic pagination", provider: .genericConnector,
                                           endpoint: URL(string: "https://pagination-fixture.invalid"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        try credentials.write("synthetic-pagination-token", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaginationProtocol.self]
        let client = CloudSyncClient(credentials: credentials, configuration: configuration)
        _ = try await client.owner(connection: connection)
        for timestamp in ["2030-01-01T00:00:00+00:00", "2030-01-01T08:00:00.123456+08:00", "2029-12-31T19:00:00-05:00"] {
            PaginationProtocol.fixture.lock.withLock {
                PaginationProtocol.fixture.timestamp = timestamp
                PaginationProtocol.fixture.reads = 0
            }
            let records = try await client.list(connection: connection)
            precondition(records.count == 1 && records[0].id == PaginationProtocol.fixture.record)
            precondition(PaginationProtocol.fixture.lock.withLock { PaginationProtocol.fixture.reads == 2 })
        }
        print("PASS: real sync client follows timezone-bearing cursors through the connector query-decoding contract")
        let pending = CloudSyncPending(requestID: UUID(), recordID: PaginationProtocol.fixture.record,
            expectedRevision: 1, document: nil, preserveCallMedia: true)
        do {
            _ = try await client.mutate(connection: connection, pending: pending)
            preconditionFailure("Old server must reject safe deletion before any POST")
        } catch is TincallError { }
        precondition(PaginationProtocol.fixture.lock.withLock { PaginationProtocol.fixture.deletions == 0 })
        PaginationProtocol.fixture.lock.withLock { PaginationProtocol.fixture.backupOnlyDeletion = true }
        _ = try await client.owner(connection: connection)
        let deleted = try await client.mutate(connection: connection, pending: pending)
        precondition(deleted.deleted && deleted.revision == 2)
        precondition(PaginationProtocol.fixture.lock.withLock { PaginationProtocol.fixture.deletions == 1 })
        print("PASS: real client blocks old servers and routes safe deletion to delete-backup")
    }
}
