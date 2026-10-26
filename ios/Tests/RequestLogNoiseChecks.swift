// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class NoiseProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var incoming = false
    nonisolated(unsafe) private static var callStatus = "ringing"
    nonisolated(unsafe) private static var callID = UUID()
    nonisolated(unsafe) private static var eventType: String?
    static func reply(status: Int = 200, incoming: Bool = false, callStatus: String = "ringing", callID: UUID? = nil, eventType: String? = nil) {
        lock.withLock {
            self.status = status; self.incoming = incoming; self.callStatus = callStatus
            if let callID { self.callID = callID }
            self.eventType = eventType
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "log-noise.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, incoming, callStatus, callID, eventType) = Self.lock.withLock { (Self.status, Self.incoming, Self.callStatus, Self.callID, Self.eventType) }
        if status == 200, request.httpMethod == "GET", request.url!.path.contains("/media/") {
            let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url!.path == "/calls/incoming/events" {
            precondition(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
            if status == 200 {
                let event: [String: Any] = ["call": ["id": callID.uuidString, "contact_id": "合成联系人", "source": "mcp",
                    "status": "ringing", "epoch": 1, "last_sequence": 1]]
                let json = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
                let bytes = Data(": keepalive\r\n\r\nevent: call_state\r\ndata: {\"call\":null}\r\n\r\ndata: \(json)\n\n".utf8)
                for offset in stride(from: 0, to: bytes.count, by: 7) {
                    client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(offset + 7, bytes.count)))
                }
            } else { client?.urlProtocol(self, didLoad: Data("{\"error\":{\"code\":\"unauthorized\"}}".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let payload: [String: Any]
        if status != 200 { payload = ["error": ["code": "unauthorized"]] }
        else if request.url!.path == "/calls/current" {
            payload = ["call": incoming ? ["id": callID.uuidString, "contact_id": "synthetic", "source": "mcp",
                "status": callStatus, "epoch": 1, "last_sequence": 0] : NSNull()]
        } else if request.url!.path == "/capabilities" {
            payload = ["owner_id": "00000000-0000-4000-8000-000000000001"]
        } else if request.url!.path == "/records" {
            payload = ["records": [], "next_cursor": NSNull()]
        } else if request.url!.lastPathComponent == "events" {
            let events: [[String: Any]] = eventType.map { type in
                [["sequence": 1, "call_id": callID.uuidString, "epoch": 1, "type": type,
                  "payload": type == "reply.delta" ? ["delta": "Synthetic reply"] : type == "reply.failed" ? ["code": "request_failed"] : [:]]]
            } ?? []
            payload = ["call": ["id": callID.uuidString, "contact_id": "synthetic", "source": "mcp",
                "status": "active", "epoch": 1, "last_sequence": events.count],
                "events": events, "cursor": events.count, "has_more": false]
        } else { payload = ["ok": true] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct RequestLogNoiseChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallNoise-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = RequestLogStore(directory: directory)
        await logs.flushPendingWrites()
        let credentials = CredentialStore()
        let connection = ConnectionProfile(name: "Synthetic log checks", provider: .genericConnector,
                                           endpoint: URL(string: "https://log-noise.invalid"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        try credentials.write("synthetic-log-noise-token", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoiseProtocol.self]
        let external = ExternalCallClient(credentials: credentials, configuration: configuration, logs: logs)
        let cloud = CloudSyncClient(credentials: credentials, configuration: configuration, logs: logs)
        let revision = logs.revision
        for _ in 0..<5 {
            let current = try await external.current(connection: connection)
            precondition(current == nil)
        }
        precondition(logs.entries.isEmpty && logs.revision == revision, "Empty incoming checks must not publish or persist logs")
        NoiseProtocol.reply(incoming: true)
        let incoming = try await external.current(connection: connection)
        precondition(incoming?.status == "ringing" && logs.entries.count == 1)
        let incomingLog = try logs.load(logs.entries)[0]
        precondition(incomingLog.requestText == "检查新来电")
        let afterIncoming = logs.revision
        for state in ["ringing", "ringing", "active", "ended"] {
            NoiseProtocol.reply(incoming: true, callStatus: state)
            _ = try await external.current(connection: connection)
        }
        precondition(logs.entries.count == 1 && logs.revision == afterIncoming,
                     "Repeated ringing and existing active/ended calls must not publish routine logs")
        NoiseProtocol.reply(status: 503)
        do { _ = try await external.current(connection: connection); preconditionFailure() }
        catch is ExternalCallFailure {}
        precondition(logs.entries.count == 2 && logs.entries.last?.httpStatus == 503 && logs.entries.last?.outcome == .failed)
        NoiseProtocol.reply()
        cloud.isAutomaticSync = true
        let beforeReads = logs.revision
        _ = try await cloud.owner(connection: connection)
        _ = try await cloud.list(connection: connection)
        precondition(logs.entries.count == 2 && logs.revision == beforeReads, "Automatic queries must stay quiet")
        try await cloud.removeMedia(connection: connection, recordID: UUID(), objectID: UUID())
        let imageBytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let mediaFile = directory.appendingPathComponent("synthetic.wav")
        try imageBytes.write(to: mediaFile)
        let media = CloudSyncMedia(object_id: UUID(), asset: CallAudioAsset(messageID: UUID(), segmentIndex: 0,
            relativePath: "synthetic.wav"), bytes: imageBytes.count)
        try await cloud.upload(connection: connection, recordID: UUID(), media: media, file: mediaFile)
        try await cloud.download(connection: connection, recordID: UUID(), media: media,
            destination: directory.appendingPathComponent("download.wav"))
        let image = CloudSyncImageReference(id: UUID(), mime_type: "image/png", bytes: imageBytes.count)
        try await cloud.downloadImage(connection: connection, recordID: UUID(), image: image,
            destination: directory.appendingPathComponent("download.png"))
        precondition(logs.entries.count == 2 && logs.revision == beforeReads,
                     "Successful automatic writes and media transfers must not publish or persist logs")
        NoiseProtocol.reply(status: 503)
        do { _ = try await cloud.list(connection: connection); preconditionFailure() }
        catch is CloudSyncFailure {}
        precondition(logs.entries.count == 3 && logs.entries.last?.httpStatus == 503 && logs.entries.last?.outcome == .failed)
        NoiseProtocol.reply()
        cloud.isAutomaticSync = false
        _ = try await cloud.owner(connection: connection)
        _ = try await cloud.list(connection: connection)
        precondition(logs.entries.count == 5 && logs.entries.suffix(2).allSatisfy { $0.outcome == .succeeded }, "Manual queries remain logged")
        try await cloud.removeMedia(connection: connection, recordID: UUID(), objectID: UUID())
        precondition(logs.entries.count == 6 && logs.entries.last?.outcome == .succeeded, "Manual cloud mutations remain logged")
        let beforeStream = logs.revision
        var received: [ExternalCallState?] = []
        try await external.incomingCalls(connection: connection) { received.append($0) }
        precondition(received.count == 2 && received[0] == nil && received[1]?.contact_id == "合成联系人")
        NoiseProtocol.reply(status: 503)
        do { try await external.incomingCalls(connection: connection) { _ in preconditionFailure() }; preconditionFailure() }
        catch let failure as ExternalCallFailure {
            precondition(failure.status == 503 && failure.code == "unauthorized",
                         "Subscription failures must retain the server code for diagnosis")
        }
        precondition(logs.entries.count == 6 && logs.revision == beforeStream,
                     "Incoming subscriptions, heartbeats and reconnect failures must never publish request logs")
        print("PASS: fragmented incoming stream, Unicode, heartbeat, failure handling and zero request-log writes")
        await logs.flushPendingWrites()
        let reopened = RequestLogStore(directory: directory)
        await reopened.flushPendingWrites()
        let saved = try reopened.load(reopened.entries)
        precondition(saved.count == 6 && saved.filter { $0.outcome == .failed }.count == 2)
        precondition(saved.filter { $0.outcome == .failed }.allSatisfy { $0.requestText != nil && $0.serverErrorText != nil })
        let eventCallID = UUID()
        let beforeEmptyEvents = logs.revision
        for type in [nil, "input.accepted", "reply.started", "call.ended"] as [String?] {
            NoiseProtocol.reply(callID: eventCallID, eventType: type)
            _ = try await external.events(connection: connection, callID: eventCallID, after: 0, wait: true)
        }
        precondition(logs.entries.count == 6 && logs.revision == beforeEmptyEvents,
                     "Empty and status-only event pages must not publish or persist request logs")
        NoiseProtocol.reply(callID: eventCallID, eventType: "reply.delta")
        _ = try await external.events(connection: connection, callID: eventCallID, after: 0, wait: true)
        precondition(logs.entries.count == 7 && logs.entries.last?.outcome == .succeeded)
        let replyLog = try logs.load([logs.entries.last!])[0]
        precondition(replyLog.responseText == "Synthetic reply")
        NoiseProtocol.reply(callID: eventCallID, eventType: "reply.failed")
        _ = try await external.events(connection: connection, callID: eventCallID, after: 0, wait: true)
        precondition(logs.entries.count == 8 && logs.entries.last?.outcome == .failed)
        NoiseProtocol.reply(status: 503)
        do { _ = try await external.events(connection: connection, callID: eventCallID, after: 0); preconditionFailure() }
        catch is ExternalCallFailure {}
        precondition(logs.entries.count == 9 && logs.entries.last?.httpStatus == 503 && logs.entries.last?.outcome == .failed)
        let summaryLog = logs.begin(service: .mcp, step: .summary)
        summaryLog.succeed(); summaryLog.finish()
        precondition(logs.entries.last?.category == .connection)
        let modelLog = logs.begin(service: .gemini, step: .summary)
        modelLog.succeed(); modelLog.finish()
        precondition(logs.entries.last?.category == .summary)
        print("PASS: empty/status event pages stay quiet; reply text, provider failures and HTTP failures remain logged; summary sync is separate from model generation")
        print("PASS: empty incoming checks and automatic cloud reads stay quiet without revisions; incoming calls, failures, mutations and manual reads persist")
    }
}
