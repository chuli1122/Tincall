// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class SummaryModelProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var requests = 0
        var fails = false
        var requestText = ""
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "summary-tasks.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
        let fails = Self.fixture.lock.withLock {
            Self.fixture.requests += 1
            Self.fixture.requestText = String(decoding: body, as: UTF8.self)
            return Self.fixture.fails
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fails ? 503 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((fails ? #"{"error":{"message":"synthetic failure"}}"#
            : #"{"choices":[{"message":{"content":"Synthetic summary"},"finish_reason":"stop"}]}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor private final class SummaryVoice: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws { }
    func setMicrophoneMuted(_ muted: Bool) async throws { }
    func setSpeakerEnabled(_ enabled: Bool) async throws { }
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws { }
    func setTextInputActive(_ active: Bool) { }
    func setSpeechInterruptionEnabled(_ enabled: Bool) { }
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws { }
    func beginReply(_ turn: VoiceTurnID) throws { }
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws { }
    func finishReply(_ turn: VoiceTurnID) throws { }
    func interruptReply(_ turn: VoiceTurnID) { }
    func stop() { }
}

@main struct CallSummaryTasksChecks {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Summary check timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let connection = ConnectionProfile(name: "Synthetic summary", provider: .openAICompatible,
            endpoint: URL(string: "https://summary-tasks.invalid"), model: "synthetic")
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        try credentials.write("synthetic-summary-key", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryModelProtocol.self]
        let model = ChatCompletionClient(credentials: credentials, configuration: configuration)
        let coordinator = CallCoordinator(voice: SummaryVoice(), model: model, summaryUserName: { "Synthetic user" })
        let role = CallRole(name: "Synthetic contact", summaryConnectionID: connection.id)
        var record = CallRecord(roleID: role.id, roleName: role.name, endedAt: Date())
        record.messages = [CallMessage(turnID: UUID(), role: .user, text: "Initial synthetic input", status: .completed)]
        var saved: [CallRecord] = []
        coordinator.onSaveRecord = { saved.append($0) }
        coordinator.record = record
        coordinator.records[record.id] = record
        var releaseGeneration: CheckedContinuation<Void, Never>?
        let generation = Task { @MainActor in
            await withCheckedContinuation { releaseGeneration = $0 }
            coordinator.mutate(record.id) { $0.messages[0].text = "Final input after cancellation" }
            coordinator.tasks.removeValue(forKey: record.id)
        }
        coordinator.tasks[record.id] = generation
        coordinator.requestSummary(for: record, connections: [connection], roles: [role])
        coordinator.requestSummary(for: record, connections: [connection], roles: [role])
        precondition(saved.count == 1 && saved[0].summaryStatus == .pending)
        precondition(!coordinator.canForgetRecord(record.id))
        coordinator.forgetRecord(record.id)
        precondition(coordinator.records[record.id] != nil)
        try await until { releaseGeneration != nil }
        precondition(SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.requests } == 0)
        releaseGeneration?.resume()
        try await until { coordinator.canForgetRecord(record.id) }
        precondition(saved.map(\.summaryStatus) == [.pending, .generating, .completed])
        precondition(SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.requests } == 1)
        precondition(SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.requestText.contains("Final input after cancellation") })
        precondition(saved.last?.summary == "Synthetic summary" && saved.last?.summaryUploadRequestID != nil)
        print("PASS: duplicate summaries coalesce; deletion is blocked; generation unwinds before the latest transcript is read")

        // Idle storage edits must win over a stale coordinator copy when retrying a summary.
        record.messages[0].text = "Manually edited input"
        SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.fails = true }
        coordinator.requestSummary(for: record, connections: [connection], roles: [role])
        try await until { coordinator.canForgetRecord(record.id) }
        precondition(saved.last?.summaryStatus == .failed && saved.last?.messages[0].text == "Manually edited input")
        precondition(coordinator.errorMessage != nil)
        SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.fails = false }
        coordinator.requestSummary(for: record, connections: [connection], roles: [role])
        try await until { coordinator.canForgetRecord(record.id) }
        precondition(saved.last?.summaryStatus == .completed)
        print("PASS: failure releases the task for retry and preserves manual record edits")

        let count = SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.requests }
        coordinator.onSaveRecord = { _ in throw TincallError(message: "Synthetic disk failure") }
        coordinator.requestSummary(for: record, connections: [connection], roles: [role])
        precondition(!coordinator.summaryTasks.isRunning(record.id) && coordinator.savingCallIDs.contains(record.id))
        precondition(SummaryModelProtocol.fixture.lock.withLock { SummaryModelProtocol.fixture.requests } == count)
        coordinator.onSaveRecord = { saved.append($0) }
        coordinator.retrySaving()
        try await until { coordinator.canForgetRecord(record.id) }
        precondition(saved.last?.summaryStatus == .completed)
        coordinator.forgetRecord(record.id)
        precondition(coordinator.records[record.id] == nil && !coordinator.summaryTasks.isConfigured(record.id))
        print("PASS: failed pending save prevents model work; save retry resumes and completed records can be forgotten")

        var pending = record
        pending.id = UUID()
        pending.summaryStatus = .generating
        coordinator.resumePendingSummaries(from: [pending], connections: [connection], roles: [role])
        try await until { coordinator.canForgetRecord(pending.id) }
        precondition(saved.last?.id == pending.id && saved.last?.summaryStatus == .completed)
        print("PASS: an interrupted summary resumes from its stored record")
    }
}
