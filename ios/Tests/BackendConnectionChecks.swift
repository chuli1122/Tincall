// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class BackendControlProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        let callID = UUID()
        var outcome = "cancel_delivery_failed"
        var controlled = false
        var ended = false
        var waited = false
        func call() -> [String: Any] {
            ["id": callID.uuidString, "contact_id": "synthetic", "source": "backend",
             "status": ended ? "ended" : "active", "epoch": controlled ? 2 : 1, "last_sequence": controlled ? 4 : 2]
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "backend-check.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result: [String: Any] = Self.state.lock.withLock {
            let state = Self.state
            if request.httpMethod == "POST" {
                state.controlled = true
                state.ended = request.url!.path.hasSuffix("/end")
                return ["call": state.call()]
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let after = Int(query.first { $0.name == "after" }!.value!)!
            let wait = query.first { $0.name == "wait" }?.value == "20"
            state.waited = state.waited || wait
            var events: [[String: Any]] = []
            if state.controlled {
                events = [
                    ["sequence": 3, "call_id": state.callID.uuidString, "epoch": 1,
                     "type": state.outcome == "none" ? "reply.completed" : "reply.interrupted", "payload": [:]],
                    ["sequence": 4, "call_id": state.callID.uuidString, "epoch": 2,
                     "type": state.ended ? "call.ended" : "call.interrupted", "payload": [:]]
                ]
                if wait && state.outcome != "missing" {
                    events.append(["sequence": 5, "call_id": state.callID.uuidString, "epoch": 2,
                                   "type": "generation.cancel_result", "payload": ["epoch": 0, "code": "cancel_delivery_failed"]])
                    events.append(["sequence": 6, "call_id": state.callID.uuidString, "epoch": 2,
                                   "type": "generation.cancel_result", "payload": ["epoch": 1, "code": state.outcome]])
                }
            }
            events = events.filter { ($0["sequence"] as! Int) > after }
            return ["call": state.call(), "events": events, "cursor": events.last?["sequence"] ?? after, "has_more": false]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor private final class BackendCheckVoice: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    var stopped = false
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
    func stop() { stopped = true }
}

@main struct BackendConnectionChecks {
    @MainActor static func main() async throws {
        let connection = ConnectionProfile(name: "Synthetic", provider: .genericConnector, endpoint: URL(string: "https://backend-check.invalid"))
        DataSharingConsent.setAllowed(true, for: connection)
        defer { DataSharingConsent.setAllowed(false, for: connection) }
        let credentials = CredentialStore()
        try credentials.write("synthetic-only", connectionID: connection.id)
        defer { try? credentials.delete(connectionID: connection.id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendControlProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincall-backend-check-\(UUID())")
        let client = ExternalCallClient(credentials: credentials, configuration: configuration, logs: RequestLogStore(directory: directory))
        let state = BackendControlProtocol.state
        for outcome in ["cancel_accepted", "cancel_delivery_failed", "missing", "none"] {
            state.lock.withLock { state.outcome = outcome; state.controlled = false; state.ended = false; state.waited = false }
            let result = try await client.control(connection: connection, callID: state.callID,
                pending: ExternalPendingControl(requestID: UUID(), epoch: 1, endsCall: false))
            precondition(result.status == "active" && result.epoch == 2)
            precondition(result.cancellationCode == (outcome == "none" ? nil : outcome == "missing" ? "cancel_unconfirmed" : outcome))
            precondition(state.lock.withLock { state.waited } == (outcome != "none"))
        }
        print("PASS: backend cancellation confirms the right epoch, surfaces failure/unknown, and skips completed generation")

        state.lock.withLock { state.controlled = false; state.waited = false }
        _ = try await client.control(connection: connection, callID: state.callID,
            pending: ExternalPendingControl(requestID: UUID(), epoch: 1, endsCall: false), confirmCancellation: false)
        precondition(!state.lock.withLock { state.waited }, "Control acknowledgement must not wait for cancellation monitoring")

        state.lock.withLock { state.outcome = "cancel_delivery_failed"; state.controlled = false; state.ended = false; state.waited = false }
        let voice = BackendCheckVoice()
        let coordinator = CallCoordinator(voice: voice, external: client)
        let session = VoiceSessionID(callID: state.callID, epoch: UUID())
        let assistant = CallMessage(turnID: UUID(), role: .assistant, text: "synthetic partial", status: .generating)
        let record = CallRecord(id: state.callID, roleID: UUID(), roleName: "Synthetic", messages: [assistant], callMode: .backend,
            externalConnectionID: connection.id, externalRoleID: "synthetic", externalCallID: state.callID, externalEventCursor: 2, externalEpoch: 1)
        coordinator.record = record; coordinator.records[record.id] = record
        coordinator.session = session; coordinator.phase = .active; coordinator.generation = .generating
        coordinator.turns[record.id] = VoiceTurnID(session: session, turnID: assistant.turnID, messageID: assistant.id)
        coordinator.externalConnections[record.id] = connection
        coordinator.onSaveRecord = { _ in }
        coordinator.hangUp()
        precondition(voice.stopped && coordinator.phase == .ended && coordinator.session == nil,
                     "Remote confirmation must never delay local manual hangup")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while coordinator.record?.externalPendingControl != nil || coordinator.errorMessage == nil {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(coordinator.errorMessage?.contains("后端") == true && coordinator.errorMessage?.contains("取消") == true)
        precondition(coordinator.record?.messages.first?.text == "synthetic partial")
        precondition(coordinator.record?.messages.first?.status == .interrupted)
        print("PASS: manual hangup stops audio immediately, retains received text, and reports remote cancellation failure")
    }
}
