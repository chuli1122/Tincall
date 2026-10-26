// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class ScheduleProtocol: URLProtocol, @unchecked Sendable {
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var supported = false
        var saved: [String: Any]?
        var writes = 0
    }
    static let fixture = Fixture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "schedule.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                precondition(count >= 0)
                if count == 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body = data.isEmpty ? [:] : try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let result: [String: Any] = Self.fixture.lock.withLock {
            let f = Self.fixture
            if request.url!.path == "/capabilities" { return f.supported ? ["schedule_controls": true] : [:] }
            if request.httpMethod == "GET" { return ["schedules": f.saved.map { [$0] } ?? []] }
            f.writes += 1
            if request.url!.path == "/schedules" {
                f.saved = body.merging(["id": body["schedule_id"]!, "next_at": "2030-01-01T00:00:00Z"]) { _, new in new }
            } else if request.url!.path == "/schedules/enabled" {
                precondition(body["enabled"] is Bool && body["schedule_id"] != nil && body["request_id"] != nil)
                f.saved?["enabled"] = body["enabled"]
            } else { precondition(request.url!.path == "/schedules/remove"); f.saved = nil }
            return ["ok": true]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct ScheduleClientChecks {
    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let connection = ConnectionProfile(name: "Synthetic schedule", provider: .genericConnector, endpoint: URL(string: "https://schedule.invalid"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        try credentials.write("synthetic-fixture-only", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScheduleProtocol.self]
        let client = ExternalCallClient(credentials: credentials, configuration: config)
        let id = UUID(), role = UUID()
        do {
            try await client.saveSchedule(connection: connection, requestID: UUID(), id: id, roleID: role,
                time: "09:00", timeZone: "Asia/Shanghai", enabled: false, weekDay: 7)
            preconditionFailure("An old service must not silently save weekly input as daily")
        } catch is TincallError { }
        let f = ScheduleProtocol.fixture
        f.lock.withLock { precondition(f.writes == 0); f.supported = true }
        try await client.saveSchedule(connection: connection, requestID: UUID(), id: id, roleID: role,
            time: "09:00", timeZone: "Asia/Shanghai", enabled: false, weekDay: 7)
        var saved = try await client.schedules(connection: connection)
        precondition(saved.count == 1 && saved[0].week_day == 7 && !saved[0].enabled)
        try await client.setScheduleEnabled(connection: connection, requestID: UUID(), id: id, enabled: true)
        saved = try await client.schedules(connection: connection)
        precondition(saved[0].enabled)
        try await client.saveSchedule(connection: connection, requestID: UUID(), id: id, roleID: role,
            time: "10:00", timeZone: "Asia/Shanghai")
        saved = try await client.schedules(connection: connection)
        precondition(saved[0].week_day == nil && saved[0].enabled)
        try await client.removeSchedule(connection: connection, requestID: UUID(), id: id)
        saved = try await client.schedules(connection: connection)
        precondition(saved.isEmpty)
        print("PASS: old service is rejected before writes; weekly/day selection, paused edits, switch and deletion use production requests")
    }
}
