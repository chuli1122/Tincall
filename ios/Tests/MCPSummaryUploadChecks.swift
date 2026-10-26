// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class SummaryProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var status = 503
        var requests: [[String: String]] = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "summary-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.httpMethod == "POST" && request.url!.path.hasSuffix("/summary"))
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-summary-token")
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0)
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try! JSONDecoder().decode([String: String].self, from: data)
        let status = Self.fixture.lock.withLock {
            Self.fixture.requests.append(body)
            return Self.fixture.status
        }
        let callID = request.url!.pathComponents.dropLast().last!
        let payload: [String: Any] = status == 200
            ? ["call": ["id": callID, "contact_id": "fixture", "source": "mcp", "status": "ended", "epoch": 1, "last_sequence": 1]]
            : ["error": ["code": "database_unavailable"], "text": body["text"]!]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct MCPSummaryUploadChecks {
    private struct RestartFixture: Codable {
        var connection: ConnectionProfile
        var completed: CallRecord
        var pending: CallRecord
        var legacy: CallRecord
    }

    private static func allowRetry(in directory: URL, connectionID: UUID, callID: UUID, requestID: UUID) throws {
        let file = directory.appendingPathComponent(connectionID.uuidString).appendingPathComponent("\(callID.uuidString).json")
        var states = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: [String: Any]]
        for key in states.keys where (states[key]?["requestID"] as? String) == requestID.uuidString {
            states[key]?["retryAfter"] = Date.distantPast.timeIntervalSinceReferenceDate
        }
        try JSONSerialization.data(withJSONObject: states).write(to: file, options: .atomic)
    }

    @MainActor static func main() async throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("SummaryUploadCheckFixture", isDirectory: true)
        let restarting = CommandLine.arguments.contains("--verify-restart")
        if !restarting, FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureFile = root.appendingPathComponent("restart.json")
        let restart = restarting ? try JSONDecoder().decode(RestartFixture.self, from: Data(contentsOf: fixtureFile)) : nil
        let credentials = CredentialStore()
        let connection = restart?.connection ?? ConnectionProfile(name: "Summary fixture", provider: .genericConnector,
            endpoint: URL(string: "https://summary-fixture.invalid/tincall"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        try credentials.write("synthetic-summary-token", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallSummaryLogs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = RequestLogStore(directory: directory)
        let uploadDirectory = root.appendingPathComponent("uploads", isDirectory: true)
        let client = ExternalCallClient(credentials: credentials, configuration: configuration, logs: logs,
            summaryUploadDirectory: uploadDirectory)
        if let restart {
            SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.status = 200 }
            for record in [restart.completed, restart.pending, restart.legacy] {
                await client.uploadSummary(for: record, connection: connection)
            }
            precondition(SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests.isEmpty },
                         "Relaunch must retain completed uploads and failed-upload cooldowns")
            precondition(logs.entries.isEmpty)
            try FileManager.default.removeItem(at: root)
            print("PASS: process restart retains completed summaries, legacy receipts and retry cooldowns")
            return
        }
        var record = CallRecord(roleID: UUID(), roleName: "Fixture", endedAt: Date(), summaryStatus: .completed,
            summary: "synthetic summary must remain local and absent from diagnostics", summaryUploadRequestID: UUID(),
            callMode: .mcp, externalConnectionID: connection.id, externalCallID: UUID())
        let restored = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(record))
        precondition(restored.summaryUploadRequestID == record.summaryUploadRequestID)
        await client.uploadSummary(for: record, connection: connection)
        precondition(record.summaryStatus == .completed && record.summary == restored.summary)
        precondition(logs.entries.contains { $0.context?.callID == record.id && $0.step == .summary && $0.outcome == .failed })
        await client.uploadSummary(for: restored, connection: connection)
        precondition(SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests.count } == 1,
                     "Repeated sync must not immediately retry a failed summary upload")
        let anotherClient = ExternalCallClient(credentials: credentials, configuration: configuration, logs: logs,
            summaryUploadDirectory: uploadDirectory)
        await anotherClient.uploadSummary(for: restored, connection: connection)
        precondition(SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests.count } == 1)
        try allowRetry(in: uploadDirectory, connectionID: connection.id, callID: record.externalCallID!, requestID: record.summaryUploadRequestID!)
        SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.status = 200 }
        await client.uploadSummary(for: restored, connection: connection)
        await client.uploadSummary(for: restored, connection: connection)
        record.summary = "synthetic regenerated summary"; record.summaryUploadRequestID = UUID()
        await client.uploadSummary(for: record, connection: connection)
        let requests = SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests }
        precondition(requests.count == 3 && requests[0] == requests[1])
        precondition(requests[2]["request_id"] != requests[0]["request_id"] && requests[2]["text"] == record.summary)
        for mode in [CallMode.standalone, .backend] {
            var excluded = record; excluded.callMode = mode
            await client.uploadSummary(for: excluded, connection: connection)
        }
        var excluded = record; excluded.externalCallID = nil
        await client.uploadSummary(for: excluded, connection: connection)
        excluded = record; excluded.summaryStatus = .generating
        await client.uploadSummary(for: excluded, connection: connection)
        precondition(SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests.count } == 3)
        var pending = record
        pending.id = UUID(); pending.externalCallID = UUID(); pending.summaryUploadRequestID = UUID()
        SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.status = 503 }
        let pendingRecord = pending
        let first = Task { @MainActor in await client.uploadSummary(for: pendingRecord, connection: connection) }
        let second = Task { @MainActor in await anotherClient.uploadSummary(for: pendingRecord, connection: connection) }
        await first.value
        await second.value
        precondition(SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests.count } == 4,
                     "Concurrent sync callers must share one failed attempt and cooldown")
        var legacy = record
        legacy.id = UUID(); legacy.externalCallID = UUID(); legacy.summaryUploadRequestID = nil
        await client.uploadSummary(for: legacy, connection: connection)
        await client.uploadSummary(for: legacy, connection: connection)
        precondition(SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests.count } == 5)
        let legacyRequest = SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.requests[4] }
        try allowRetry(in: uploadDirectory, connectionID: connection.id, callID: legacy.externalCallID!, requestID: UUID(uuidString: legacyRequest["request_id"]!)!)
        SummaryProtocol.fixture.lock.withLock { SummaryProtocol.fixture.status = 200 }
        await anotherClient.uploadSummary(for: legacy, connection: connection)
        await client.uploadSummary(for: legacy, connection: connection)
        precondition(SummaryProtocol.fixture.lock.withLock {
            SummaryProtocol.fixture.requests.count == 6 && SummaryProtocol.fixture.requests[5] == legacyRequest
        }, "Legacy summaries must reuse the saved request ID for retries")
        let encodedLogs = String(decoding: try JSONEncoder().encode(logs.entries.filter { $0.context?.callID == record.id }), as: UTF8.self)
        precondition(!encodedLogs.contains(record.summary) && !encodedLogs.contains(restored.summary) && !encodedLogs.contains("synthetic-summary-token"))
        precondition(!logs.entries.contains { $0.context?.callID == record.id && $0.outcome == .succeeded },
                     "Successful background summary uploads must not create request logs")
        precondition(logs.entries.allSatisfy { $0.category == .connection && $0.outcome == .failed })
        await logs.flushPendingWrites()
        try JSONEncoder().encode(RestartFixture(connection: connection, completed: record, pending: pending, legacy: legacy))
            .write(to: fixtureFile, options: .atomic)
        print("PASS: persistent summary receipts, retry backoff, concurrent deduplication, legacy request IDs and regeneration")
    }
}
