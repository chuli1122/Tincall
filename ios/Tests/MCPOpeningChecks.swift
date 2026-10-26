// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

// Isolated network and audio fixtures; exercises the production coordinator/transport.
private final class OpeningProtocol: URLProtocol, @unchecked Sendable {
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var call = UUID()
        var reply = UUID()
        var available = 3
        var epoch = 0
        var ended = false
        var endReason = "hangup"
        var pageLimit = 100
        var source = "mcp"
        var contactID = "synthetic"
        var modelRequests: [[[String: Any]]] = []
        var holdModel = false
        var heldModel: OpeningProtocol?
        var cancelledModels = 0
        var failNextEvents = false
        var createRequests = 0
        var answerRequests = 0
        var submittedReply: UUID?
        var inputTexts: [String] = []
        var timePreferenceBodies: [[String: Any]] = []
        func state() -> [String: Any] {
            ["id":call.uuidString,"contact_id":contactID,"source":source,"status":ended ? "ended" : "active","epoch":epoch,"last_sequence":available]
        }
        func events() -> [[String: Any]] {
            let base: [String: Any] = ["reply_id":reply.uuidString,"input_id":NSNull(),"opening":true]
            let initial: [[String: Any]] = [
                ["sequence":1,"call_id":call.uuidString,"epoch":0,"type":"reply.started","payload":base],
                ["sequence":2,"call_id":call.uuidString,"epoch":0,"type":"reply.delta","payload":base.merging(["delta":"Hello"]) { _, new in new }],
                ["sequence":3,"call_id":call.uuidString,"epoch":0,"type":"reply.completed","payload":base.merging(["text":"Hello there."]) { _, new in new }],
                ["sequence":4,"call_id":call.uuidString,"epoch":1,"type":"call.ended","payload":["reason":endReason]],
            ]
            if let submittedReply {
                let next: [String: Any] = ["reply_id":submittedReply.uuidString,"input_id":NSNull(),"submitted":true]
                return Array(initial.prefix(3)) + [
                    ["sequence":4,"call_id":call.uuidString,"epoch":1,"type":"call.interrupted","payload":["reason":"interrupted"]],
                    ["sequence":5,"call_id":call.uuidString,"epoch":0,"type":"reply.started","payload":next],
                    ["sequence":6,"call_id":call.uuidString,"epoch":0,"type":"reply.completed","payload":next.merging(["text":"A new complete reply."]) { _, new in new }],
                ]
            }
            return initial
        }
    }
    static let fixture = Fixture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-opening.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path == "/calls" || request.url!.path.hasSuffix("/answer") {
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
            if !data.isEmpty {
                let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                Self.fixture.lock.withLock { Self.fixture.timePreferenceBodies.append(body) }
            }
        }
        if request.url!.path == "/calls", request.httpMethod == "POST" {
            Self.fixture.lock.withLock { Self.fixture.createRequests += 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":{\"code\":\"call_busy\"}}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url!.path.hasSuffix("/events"), Self.fixture.lock.withLock({
            let fail = Self.fixture.failNextEvents
            Self.fixture.failNextEvents = false
            return fail
        }) {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if request.url!.path.hasSuffix("/chat/completions") {
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
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            Self.fixture.lock.withLock { Self.fixture.modelRequests.append(body["messages"] as! [[String: Any]]) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello from \"}}]}\n\n".utf8))
            let held = Self.fixture.lock.withLock {
                if Self.fixture.holdModel { Self.fixture.heldModel = self; return true }
                return false
            }
            if !held { finishModel() }
            return
        }
        let result: [String: Any] = Self.fixture.lock.withLock {
            let f = Self.fixture
            if request.url!.path.hasSuffix("/answer") { f.answerRequests += 1 }
            if request.url!.path.hasSuffix("/events") {
                let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
                let events = Array(f.events().filter { ($0["sequence"] as! Int) > after && ($0["sequence"] as! Int) <= f.available }.prefix(f.pageLimit))
                return ["call":f.state(),"events":events,"cursor":events.last?["sequence"] ?? after,"has_more":(events.last?["sequence"] as? Int ?? after) < f.available]
            }
            if request.url!.path.hasSuffix("/input") {
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating:0, count:4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&bytes, maxLength:bytes.count)
                        precondition(count >= 0)
                        if count == 0 { break }
                        data.append(contentsOf:bytes.prefix(count))
                    }
                }
                let input = try! JSONSerialization.jsonObject(with:data) as! [String:Any]
                f.inputTexts.append(input["text"] as! String)
                f.epoch += 1
                return ["call":f.state(),"input_id":input["message_id"]!,"reply_id":UUID().uuidString,"epoch":f.epoch]
            }
            if request.url!.path.hasSuffix("/interrupt") { f.epoch = 1; f.available = 4 }
            if request.url!.path.hasSuffix("/end") { f.ended = true; f.epoch += 1 }
            return ["call":f.state()]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields:["Content-Type":"application/json"])!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
    func finishModel() {
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"scheduled call.\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if request.url?.path.hasSuffix("/chat/completions") == true {
            Self.fixture.lock.withLock { Self.fixture.cancelledModels += 1; Self.fixture.heldModel = nil }
        }
    }
}

@MainActor private final class OpeningVoice: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    var beginCount = 0
    var failBegin = false
    var failAppendFor: UUID?
    var failFinishFor: UUID?
    var switches = 0
    var finished = false
    var appended = ""
    var prefetchedFinished = false
    var prepared: VoiceTurnID?
    var active = false
    var interrupted: VoiceTurnID?
    var session: VoiceSessionID?
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws { prepared = turn }
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws {
        self.session = session
        active = true
        if let prepared { try beginReply(prepared); finished = prefetchedFinished }
    }
    func setMicrophoneMuted(_ muted: Bool) async throws { }
    func setSpeakerEnabled(_ enabled: Bool) async throws { }
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws { switches += 1 }
    func setTextInputActive(_ active: Bool) { }
    func setSpeechInterruptionEnabled(_ enabled: Bool) { }
    func beginReply(_ turn: VoiceTurnID) throws { beginCount += 1; if failBegin { throw TincallError(message: "Synthetic synthesis failure") } }
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws {
        if turn.messageID == failAppendFor {
            onEvent?(.playback(turn, .failed))
            throw TincallError(message: "Synthetic append failure")
        }
        appended += delta
    }
    func finishReply(_ turn: VoiceTurnID) throws {
        if turn.messageID == failFinishFor {
            onEvent?(.playback(turn, .failed))
            throw TincallError(message: "Synthetic finish failure")
        }
        if !active, prepared == turn { prefetchedFinished = true }
        else { finished = true }
    }
    func interruptReply(_ turn: VoiceTurnID) { interrupted = turn; prepared = nil }
    func stop() { }
}

@main struct MCPOpeningChecks {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() { precondition(Date() < deadline, "Synthetic opening timed out"); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let connector = ConnectionProfile(name:"Synthetic MCP", provider:.genericConnector, endpoint:URL(string:"https://mcp-opening.invalid"))
        let stt = ConnectionProfile(name:"Synthetic STT", provider:.appleSpeech)
        let tts = ConnectionProfile(name:"Synthetic TTS", provider:.elevenLabs, model:"eleven_v3", voiceID:"synthetic")
        for value in [connector,tts] { try credentials.write("synthetic-fixture-only", connectionID:value.id) }
        defer { for value in [connector,tts] { try? credentials.delete(connectionID:value.id) } }
        var role = CallRole(name:"Synthetic", sttConnectionID:stt.id, ttsConnectionID:tts.id)
        role.callMode = .mcp; role.externalConnectionID = connector.id; role.externalRoleID = "synthetic"
        for connection in [connector, tts] { DataSharingConsent.setAllowed(true, for: connection) }
        defer {
            for connection in [connector, tts] {
                UserDefaults.standard.removeObject(forKey: "tincall.dataSharing.v1.\(connection.id.uuidString)")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpeningProtocol.self]
        let voice = OpeningVoice()
        let call = CallCoordinator(voice:voice, external:ExternalCallClient(credentials:credentials, configuration:configuration))
        call.onSaveRecord = { _ in }
        let f = OpeningProtocol.fixture
        let callID = f.lock.withLock { f.call }
        if CommandLine.arguments.contains("--unanswered-inputs-only") {
            f.lock.withLock { f.available = 0 }
            try await call.prepareIncoming(callID: callID, role: role, connector: connector,
                connections: [connector, stt, tts], retention: AudioRetention())
            try await call.confirmIncoming(callID: callID)
            try await call.activatePreparedIncoming(callID: callID)
            call.setSpeechInterruptionEnabled(false)
            let identity = call.session!
            let first = TranscriptResult(inputID: UUID(), text: "First unanswered sentence", isFinal: true)
            let second = TranscriptResult(inputID: UUID(), text: "A follow-up before any reply", isFinal: true)
            voice.onEvent?(.transcript(identity, first))
            try await until { call.record?.externalPendingInput == nil && f.lock.withLock { f.inputTexts.count == 1 } }
            voice.onEvent?(.transcript(identity, second))
            try await Task.sleep(for: .milliseconds(300))
            precondition(f.lock.withLock { f.inputTexts == [first.text, second.text] },
                "An unanswered MCP message must not block the next spoken message when speech interruption is off")
            precondition(call.record!.messages.filter { $0.role == .user }.map(\.text) == [first.text, second.text])
            precondition(call.pendingInputCount == 0 && call.isCallActive && voice.appended.isEmpty)
            call.setSpeechInterruptionEnabled(true)
            let third = TranscriptResult(inputID: UUID(), text: "Another sentence", isFinal: true)
            let fourth = TranscriptResult(inputID: UUID(), text: "Before the previous upload returns", isFinal: true)
            voice.onEvent?(.transcript(identity, third))
            voice.onEvent?(.transcript(identity, fourth))
            precondition(call.sendText("A typed follow-up"))
            precondition(call.sendText("One more typed message"))
            try await until { call.record?.externalPendingInput == nil && call.pendingInputCount == 0 }
            let expected = [first.text, second.text, third.text, fourth.text, "A typed follow-up", "One more typed message"]
            precondition(f.lock.withLock { f.inputTexts == expected },
                "Back-to-back speech and text must preserve every unacknowledged input in order")
            precondition(call.record!.messages.filter { $0.role == .user }.map(\.text) == expected)
            // The no-reply path must not bypass disabled speech interruption once a real reply arrives.
            call.setSpeechInterruptionEnabled(false)
            let turn = call.turns[callID]!
            call.receiveDelta("An actual reply", turn: turn)
            voice.onEvent?(.playback(turn, .playing))
            let duringPlayback = TranscriptResult(inputID: UUID(), text: "Wait until playback ends", isFinal: true)
            voice.onEvent?(.transcript(identity, duringPlayback))
            precondition(call.pendingInputCount == 1 && call.turns[callID] == turn)
            precondition(f.lock.withLock { f.inputTexts == expected })
            call.complete(turn, status: .completed)
            voice.onEvent?(.playback(turn, .drained))
            try await until { call.record?.externalPendingInput == nil && call.pendingInputCount == 0 }
            precondition(f.lock.withLock { f.inputTexts == expected + [duringPlayback.text] })
            call.hangUp()
            try await until { f.lock.withLock { f.ended } }
            print("PASS: unanswered MCP inputs never block follow-ups; pending speech/text uploads stay ordered; real playback still respects speech interruption")
            return
        }
        if CommandLine.arguments.contains("--time-awareness-only") {
            let client = ExternalCallClient(credentials: credentials, configuration: configuration)
            let user = CallMessage(turnID: UUID(), role: .user, text: "Meet on 2026-10-25 at 12:30.", createdAt: Date(timeIntervalSince1970: 0))
            var pending = ExternalPendingInput(requestID: UUID(), messageID: user.id, replyMessageID: UUID(), epoch: 0,
                timeZone: "Asia/Shanghai")
            _ = try await client.input(connection: connector, callID: callID, pending: pending, text: user.text, createdAt: user.createdAt)
            pending.timeZone = nil
            _ = try await client.input(connection: connector, callID: callID, pending: pending, text: user.text, createdAt: user.createdAt)
            precondition(f.lock.withLock { f.inputTexts } == ["[1970-01-01 08:00:00]\n" + user.text, user.text])
            precondition(user.text == "Meet on 2026-10-25 at 12:30.")
            for enabled in [true, false] {
                let testVoice = OpeningVoice()
                let testCall = CallCoordinator(voice: testVoice)
                testCall.onSaveRecord = { _ in }
                var testRole = role
                testRole.timeAwarenessEnabled = enabled
                do {
                    _ = try await client.create(connection: connector, role: testRole, callID: callID, expressionPrompt: "")
                    preconditionFailure("Synthetic create must return its busy response")
                } catch let failure as ExternalCallFailure { precondition(failure.code == "call_busy") }
                _ = try await client.answer(connection: connector, callID: callID, requestID: UUID(), epoch: 0, expressionPrompt: "",
                    timeAwarenessEnabled: enabled)
                for body in f.lock.withLock({ Array(f.timePreferenceBodies.suffix(2)) }) {
                    precondition(body["time_awareness_enabled"] as? Bool == (enabled ? true : nil))
                    precondition(body["time_zone"] as? String == (enabled ? TimeZone.autoupdatingCurrent.identifier : nil))
                }
                testCall.role = testRole
                let id = UUID(), replyID = UUID()
                let identity = VoiceSessionID(callID: id, epoch: UUID())
                let message = CallMessage(id: replyID, turnID: UUID(), role: .assistant, text: "", status: .generating)
                var record = CallRecord(id: id, roleID: role.id, roleName: role.name, callMode: .mcp)
                record.messages = [message]
                testCall.session = identity; testCall.phase = .active
                testCall.records[id] = record; testCall.record = record
                testCall.turns[id] = VoiceTurnID(session: identity, turnID: message.turnID, messageID: message.id)
                testCall.externalReplyIDs[id] = replyID
                testCall.generation = .generating
                testCall.playback = .synthesizing
                let first = "[2026-10-"
                let second = "25 12:01:02]\nMeet on 2026-10-25 at 12:30."
                let state = ExternalCallState(id: id, contact_id: "synthetic", source: "mcp", status: "active", epoch: 0, last_sequence: 3)
                func page(_ sequence: Int, type: String, delta: String? = nil, text: String? = nil) -> ExternalEventPage {
                    let payload = ExternalCallEvent.Payload(reply_id: replyID, input_id: nil, delta: delta, text: text,
                        code: nil, reason: nil, epoch: nil, opening: true, submitted: nil)
                    return ExternalEventPage(call: state, events: [ExternalCallEvent(sequence: sequence, call_id: id, epoch: 0, type: type, payload: payload)],
                        cursor: sequence, has_more: sequence < 3)
                }
                try testCall.receiveExternalPage(page(1, type: "reply.delta", delta: first), session: identity)
                precondition(testCall.record!.messages[0].text == (enabled ? "" : first))
                precondition(testVoice.appended == (enabled ? "" : first))
                try testCall.receiveExternalPage(page(2, type: "reply.delta", delta: second), session: identity)
                try testCall.receiveExternalPage(page(3, type: "reply.completed", text: first + second), session: identity)
                let expected = enabled ? "Meet on 2026-10-25 at 12:30." : first + second
                precondition(testCall.record!.messages[0].text == expected && testVoice.appended == expected)
                precondition(testCall.generation == .completed && testVoice.finished)
                testCall.playback = .playing
                let nextReply = UUID()
                let queuedPayload = ExternalCallEvent.Payload(reply_id: nextReply, input_id: nil, delta: nil, text: first + second,
                    code: nil, reason: nil, epoch: nil, opening: nil, submitted: true)
                let queued = ExternalEventPage(call: state,
                    events: [ExternalCallEvent(sequence: 4, call_id: id, epoch: 0, type: "reply.completed", payload: queuedPayload)],
                    cursor: 4, has_more: false)
                try testCall.receiveExternalPage(queued, session: identity)
                precondition(testCall.record!.messages.last!.text == expected && testCall.externalReplyQueue.count == 1)
                testCall.hangUp(remotely: true)
            }
            for code in ["call_busy", "contact_mode_mismatch", "role_identity_conflict", "idempotency_conflict", "call_ended", "stale_epoch"] {
                let description = ExternalCallFailure(status: 409, code: code).errorDescription!
                precondition(description.contains(code) && description.contains("\n"), "known conflicts must carry specific guidance and preserve the real code")
            }
            precondition(ExternalCallFailure(status: 409, code: "call_busy").errorDescription !=
                ExternalCallFailure(status: 409, code: "contact_mode_mismatch").errorDescription)
            for status in [401, 403, 404, 422, 429, 500, 503] {
                let description = ExternalCallFailure(status: status, code: "unknown_error").errorDescription!
                precondition(description.contains("unknown_error") && description.contains("\n"))
            }
            precondition(ExternalCallFailure(status: 409, code: "unknown_conflict").errorDescription!.contains("\n"))
            print("PASS: phone-created input timestamps retain local text; split external timestamp prefixes never enter storage or speech; ordinary dates and disabled behavior remain intact")
            print("PASS: create/answer time preferences are opt in; queued replies are cleaned; conflict and HTTP errors include specific guidance with original codes")
            return
        }
        if CommandLine.arguments.contains("--mcp-reentrant-failure-only") {
            for step in ["append", "finish"] {
                let testVoice = OpeningVoice()
                let testCall = CallCoordinator(voice: testVoice)
                testCall.onSaveRecord = { _ in }
                let id = UUID()
                let session = VoiceSessionID(callID: id, epoch: UUID())
                testCall.session = session; testCall.phase = .active
                var record = CallRecord(id: id, roleID: UUID(), roleName: "Synthetic", callMode: .mcp)
                record.messages = (0..<4).map { CallMessage(turnID: UUID(), role: .assistant, text: "Reply \($0)", status: .completed) }
                testCall.records[id] = record; testCall.record = record
                let turns = record.messages.map { VoiceTurnID(session: session, turnID: $0.turnID, messageID: $0.id) }
                testCall.turns[id] = turns[0]; testCall.generation = .completed; testCall.playback = .playing
                for index in 1..<4 { testCall.externalReplyQueue.append((turns[index], turns[index].messageID, nil)) }
                if step == "append" { testVoice.failAppendFor = turns[1].messageID }
                else { testVoice.failFinishFor = turns[1].messageID }
                testVoice.onEvent?(.playback(turns[0], .drained))
                precondition(testCall.turns[id] == turns[2] && testVoice.beginCount == 2 && testCall.externalReplyQueue.count == 1,
                             "a synchronous failure callback must not let an old catch replace the next playing reply")
                precondition(testCall.playback == .synthesizing)
                testVoice.onEvent?(.playback(turns[2], .drained))
                precondition(testCall.turns[id] == turns[3] && testVoice.beginCount == 3 && testCall.externalReplyQueue.isEmpty)
                testCall.hangUp(remotely: true)
            }
            print("PASS: synchronous append/finish failures cannot replace the next reply before it drains")
            return
        }
        if CommandLine.arguments.contains("--stt-switch-only") {
            f.lock.withLock { f.available = 0 }
            try await call.prepareIncoming(callID: callID, role: role, connector: connector, connections: [connector, stt, tts], retention: AudioRetention())
            try await call.confirmIncoming(callID: callID)
            try await call.activatePreparedIncoming(callID: callID)
            let identity = call.session!
            let next = ConnectionProfile(name: "Synthetic Whisper", provider: .whisperCompatible)
            voice.onEvent?(.speechActivity(identity, true))
            voice.onEvent?(.speechActivity(identity, false))
            call.requestSpeechRecognitionConnection(next)
            try await Task.sleep(for: .milliseconds(50))
            precondition(voice.switches == 0 && call.isAwaitingSpeechTranscript,
                         "STT must wait for the final result even when Whisper has no partial")
            voice.onEvent?(.transcript(identity, TranscriptResult(inputID: UUID(), text: "Synthetic final", isFinal: true)))
            try await until { voice.switches == 1 }
            precondition(call.record!.messages.contains { $0.role == .user && $0.text == "Synthetic final" })
            // A new onset between the switch request and its Task must also defer it.
            call.requestSpeechRecognitionConnection(stt)
            voice.onEvent?(.speechActivity(identity, true))
            voice.onEvent?(.speechActivity(identity, false))
            try await Task.sleep(for: .milliseconds(50))
            precondition(voice.switches == 1 && call.pendingSpeechRecognitionConnection?.id == stt.id)
            voice.onEvent?(.transcript(identity, TranscriptResult(inputID: UUID(), text: "", isFinal: false)))
            try await until { voice.switches == 2 }
            call.hangUp(remotely: true)
            print("PASS: STT switching waits for pending final transcription, rechecks new onsets and resumes after final/reset")
            return
        }
        if CommandLine.arguments.contains("--mcp-queue-only") {
            for finish in ["drained", "interrupt", "hangup", "failed", "synthesis-failed"] {
                let testVoice = OpeningVoice()
                let testCall = CallCoordinator(voice: testVoice, external: ExternalCallClient(credentials: credentials, configuration: configuration))
                testCall.onSaveRecord = { _ in }
                let id = UUID()
                f.lock.withLock { f.call = id; f.available = 0; f.ended = false; f.epoch = 0 }
                try await testCall.prepareIncoming(callID: id, role: role, connector: connector, connections: [connector, stt, tts], retention: AudioRetention())
                try await testCall.confirmIncoming(callID: id)
                try await testCall.activatePreparedIncoming(callID: id)
                testCall.externalEventsTask?.cancel(); testCall.externalEventsTask = nil
                let identity = testCall.session!
                func page(_ sequence: Int, _ events: [[String: Any]], more: Bool = false) throws {
                    let body: [String: Any] = ["call": ["id": id.uuidString, "contact_id": "synthetic", "source": "mcp", "status": "active", "epoch": 0, "last_sequence": sequence],
                        "events": events, "cursor": sequence, "has_more": more]
                    try testCall.receiveExternalPage(JSONDecoder().decode(ExternalEventPage.self, from: JSONSerialization.data(withJSONObject: body)), session: identity)
                }
                func event(_ sequence: Int, _ type: String, _ payload: [String: Any]) -> [String: Any] {
                    ["sequence": sequence, "call_id": id.uuidString, "epoch": 0, "type": type, "payload": payload]
                }
                let replies = [UUID(), UUID(), UUID()]
                var events: [[String: Any]] = []
                for (index, reply) in replies.enumerated() {
                    let base: [String: Any] = ["reply_id": reply.uuidString, "input_id": NSNull(), "submitted": true]
                    events += [event(index * 2 + 1, "reply.started", base),
                               event(index * 2 + 2, "reply.completed", base.merging(["text": "Reply \(index). "]) { _, new in new })]
                }
                try page(4, Array(events.prefix(4)), more: true)
                precondition(testVoice.beginCount == 1 && testVoice.appended == "Reply 0. ", "next submitted reply must wait for current audio to drain")
                try page(6, Array(events.suffix(2)))
                try page(6, events) // duplicate page cannot enqueue another playback
                precondition(testCall.record?.messages.count == 3 && testVoice.beginCount == 1)
                let first = testCall.turns[id]!
                if finish == "interrupt" || finish == "hangup" {
                    testVoice.onEvent?(.playback(first, .playing))
                    if finish == "interrupt" { testCall.interrupt() } else { testCall.hangUp() }
                    testVoice.onEvent?(.playback(first, .drained))
                    precondition(testVoice.beginCount == 1)
                    precondition(testCall.record!.messages.allSatisfy { $0.status == .interrupted && $0.interruption != nil })
                    if testCall.isCallActive { testCall.hangUp(remotely: true) }
                } else {
                    try page(7, [event(7, "call.ended", ["reason": "mcp_hangup"])])
                    precondition(testCall.isCallActive)
                    if finish == "synthesis-failed" { testVoice.failBegin = true }
                    testVoice.onEvent?(.playback(first, finish == "failed" ? .failed : .drained))
                    if finish == "drained" {
                        precondition(testCall.isCallActive && testVoice.beginCount == 2)
                        testVoice.onEvent?(.playback(first, .drained)) // stale callback
                        precondition(testVoice.beginCount == 2)
                        testVoice.onEvent?(.playback(testCall.turns[id]!, .drained))
                        precondition(testCall.isCallActive && testVoice.beginCount == 3)
                        testVoice.onEvent?(.playback(testCall.turns[id]!, .drained))
                        precondition(testVoice.appended == "Reply 0. Reply 1. Reply 2. ")
                    }
                    precondition(!testCall.isCallActive, "MCP hangup must finish on drain or playback failure")
                }
            }
            print("PASS: consecutive MCP replies drain in order, survive pagination, deduplicate and terminate on interrupt/hangup/failure")
            return
        }
        if CommandLine.arguments.contains("--missed-call") {
            var saved: [CallRecord] = []
            call.onSaveRecord = { saved.append($0) }
            for mode in [CallMode.standalone, .mcp, .backend] {
                var caller = role
                caller.callMode = mode
                let id = UUID()
                f.lock.withLock { f.call = id; f.ended = true; f.available = 0 }
                await call.declineIncoming(callID: id, role: caller, connector: connector)
                let missed = call.records[id]!
                precondition(missed.roleID == caller.id && missed.roleName == "Synthetic（未接来电）")
                precondition(missed.callMode == mode && missed.endedAt != nil)
                precondition(missed.externalRoleID == (mode == .standalone ? caller.id.uuidString : caller.externalRoleID))
                precondition(saved.last?.roleID == caller.id && saved.last?.roleName == missed.roleName)
                try await until { call.externalControlTasks[id] == nil }
                await call.declineIncoming(callID: id, role: nil, connector: connector)
                precondition(call.records[id]?.roleName == missed.roleName, "Duplicate end callbacks must preserve identity")
                try await until { call.externalControlTasks[id] == nil }
            }
            let unknownID = UUID()
            f.lock.withLock { f.call = unknownID }
            await call.declineIncoming(callID: unknownID, role: nil, connector: connector)
            precondition(call.records[unknownID]?.roleName == "未接来电")
            try await until { call.externalControlTasks[unknownID] == nil }
            let existingID = UUID()
            f.lock.withLock { f.call = existingID }
            call.records[existingID] = CallRecord(id: existingID, roleID: role.id, roleName: role.displayName,
                endedAt: Date(), externalConnectionID: connector.id, externalCallID: existingID)
            await call.declineIncoming(callID: existingID, role: role, connector: connector)
            precondition(call.records[existingID]?.roleName == role.displayName, "Existing calls must not become missed calls")
            try await until { call.externalControlTasks[existingID] == nil }
            print("PASS: missed calls save caller name and identity for all three modes; unknown callers, duplicates and existing records remain safe")
            return
        }
        if CommandLine.arguments.contains("--mcp-message-only") {
            f.lock.withLock { f.available = 0; f.submittedReply = UUID() }
            try await call.prepareIncoming(callID: callID, role: role, connector: connector, connections: [connector, stt, tts], retention: AudioRetention())
            try await call.confirmIncoming(callID: callID)
            try await call.activatePreparedIncoming(callID: callID)
            f.lock.withLock { f.available = 3 }
            try await until { voice.finished }
            let first = call.turns[callID]!
            voice.onEvent?(.playback(first, .playing))
            call.interrupt()
            try await until { call.record?.externalPendingControl == nil }
            precondition(voice.interrupted == first)
            f.lock.withLock { f.available = 6 }
            try await until { call.record?.messages.last?.text == "A new complete reply." }
            precondition(voice.beginCount == 2 && voice.appended == "Hello there.A new complete reply.")
            precondition(call.record?.messages.first?.status == .interrupted)
            precondition(call.record?.messages.last?.status == .completed)
            precondition(call.isCallActive)
            call.hangUp(remotely: true)
            print("PASS: after interrupting playback, a newly submitted complete MCP reply starts speech and preserves the interrupted message")
            return
        }
        if CommandLine.arguments.contains("--mcp-end-only") {
            for finish in ["drained", "manual", "failed", "immediate", "already-drained"] {
                let testVoice = OpeningVoice()
                let testCall = CallCoordinator(voice: testVoice, external: ExternalCallClient(credentials: credentials, configuration: configuration))
                testCall.onSaveRecord = { _ in }
                let id = UUID()
                f.lock.withLock {
                    f.call = id; f.reply = UUID(); f.available = 0; f.ended = false; f.epoch = 0
                    f.endReason = finish == "immediate" ? "hangup" : "mcp_hangup"
                    f.pageLimit = 2
                }
                try await testCall.prepareIncoming(callID: id, role: role, connector: connector, connections: [connector, stt, tts], retention: AudioRetention())
                try await testCall.confirmIncoming(callID: id)
                try await testCall.activatePreparedIncoming(callID: id)
                if finish == "already-drained" {
                    f.lock.withLock { f.available = 3 }
                    try await until { testVoice.finished }
                    testVoice.onEvent?(.playback(testCall.turns[id]!, .drained))
                }
                f.lock.withLock { f.available = 4; f.ended = true; f.epoch = 1 }
                try await until { testCall.record?.externalEventCursor == 4 }
                precondition(testVoice.finished && testVoice.appended == "Hello there.")
                if finish == "immediate" || finish == "already-drained" {
                    precondition(!testCall.isCallActive)
                    continue
                }
                precondition(testCall.isCallActive, "MCP hangup must wait for actual playback drain")
                let turn = testCall.turns[id]!
                testVoice.onEvent?(.playback(turn, .idle))
                precondition(testCall.isCallActive, "A gap between audio segments is not completion")
                precondition(!testCall.canSend, "No new remote generation after the end request")
                if finish == "manual" {
                    testCall.hangUp()
                    precondition(!testCall.endedByRemote)
                } else {
                    testVoice.onEvent?(.playback(turn, finish == "failed" ? .failed : .drained))
                    precondition(testCall.endedByRemote)
                    if finish == "failed" { precondition(testCall.errorMessage != nil) }
                }
                precondition(!testCall.isCallActive && testCall.record?.endedAt != nil)
                if finish == "drained" { precondition(testCall.record?.messages.last?.interruption == nil) }
                testVoice.onEvent?(.playback(turn, .drained))
                precondition(!testCall.isCallActive)
            }
            print("PASS: MCP hangup drains paginated final speech; manual/ordinary hangup stays immediate; failed audio cannot strand the call")
            return
        }
        if CommandLine.arguments.contains("--connection-timing-only") {
            try await call.prepareIncoming(callID: callID, role: role, connector: connector,
                connections: [connector, stt, tts], retention: AudioRetention())
            precondition(f.lock.withLock { f.answerRequests } == 0,
                         "Local preparation must not wait for a remote answer")
            do {
                try await call.activatePreparedIncoming(callID: callID)
                preconditionFailure("An unconfirmed incoming call must not play replies or become active")
            } catch { }
            precondition(call.phase == .connecting && !voice.active)
            try await call.confirmIncoming(callID: callID)
            precondition(f.lock.withLock { f.answerRequests } == 1)
            precondition(call.phase == .connecting)
            precondition(call.record?.recordedDuration == nil,
                         "Connection setup must not count as connected call duration")
            precondition(call.connectedAt == nil, "The call view must not start its timer while connecting")
            try await Task.sleep(for: .milliseconds(150))
            let connectedAfter = Date()
            try await call.activatePreparedIncoming(callID: callID)
            precondition(call.phase == .active && call.record!.startedAt >= connectedAfter,
                         "A new call's timer must start at connection, not dialing or preparation")
            precondition(call.record?.lastActiveAt != nil)
            precondition(call.connectedAt == call.record?.startedAt)
            call.hangUp()
            precondition(call.record!.recordedDuration! < 0.15,
                         "Recorded duration must exclude time spent connecting")
            print("PASS: connecting does not count; active calls begin timing at connection")
            return
        }
        if CommandLine.arguments.contains("--redial-recovery-only") {
            let startedAt = Date().addingTimeInterval(-300)
            var saved = CallRecord(id: callID, roleID: role.id, roleName: role.name, startedAt: startedAt,
                callMode: .mcp, externalConnectionID: connector.id, externalRoleID: "synthetic",
                externalCallID: callID, externalEventCursor: 3, externalEpoch: 0,
                lastActiveAt: startedAt.addingTimeInterval(90), recordedActiveDuration: 90, endedAbnormally: true)
            saved.messages = [CallMessage(turnID: UUID(), role: .assistant, text: "Previously received", status: .completed)]
            var writes: [CallRecord] = []
            call.onSaveRecord = { writes.append($0) }
            // The first attempt still encounters an offline phone. A second normal dial
            // must retry the original call rather than leave failed new-call records.
            f.lock.withLock { f.failNextEvents = true }
            await call.start(role: role, connections: [connector, stt, tts], retention: AudioRetention(), historyRecords: [saved])
            precondition(call.phase == .failed && call.record?.id == callID && call.record?.endedAt == nil,
                         "A failed reconnect must preserve the original resumable call")
            precondition(f.lock.withLock { f.createRequests } == 0,
                         "Redial must resume the unfinished call without trying to create an occupied call")
            await call.start(role: role, connections: [connector, stt, tts], retention: AudioRetention(), historyRecords: [saved])
            precondition(call.phase == .active && call.errorMessage == nil && call.record?.id == callID)
            precondition(call.record?.startedAt == startedAt && (call.record?.recordedDuration ?? 0) >= 90,
                         "Reconnection must retain the original timer and accumulated active duration")
            precondition(call.record?.externalEventCursor == 3 && call.record?.messages == saved.messages)
            precondition(voice.appended.isEmpty && writes.allSatisfy { $0.id == callID },
                         "Recovery must not replay old audio or create duplicate records")
            call.hangUp()
            try await until { f.lock.withLock { f.ended } }
            print("PASS: normal redial retries/resumes the original unfinished call with its timer, cursor and record intact")
            let finished = call.record!
            await call.start(role: role, connections: [connector, stt, tts], retention: AudioRetention(), historyRecords: [finished])
            precondition(f.lock.withLock { f.createRequests } == 1 && call.record?.id != callID,
                         "An explicitly ended call must use a new dial, never resume")
            var changedRole = role
            changedRole.id = UUID()
            await call.start(role: changedRole, connections: [connector, stt, tts], retention: AudioRetention(), historyRecords: [saved])
            precondition(f.lock.withLock { f.createRequests } == 2 && call.record?.id != callID,
                         "Another contact must not resume this contact's unfinished call")
            var pendingHangup = saved
            pendingHangup.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: 0, endsCall: true)
            // A fresh coordinator represents the relaunched app's persisted hangup outbox.
            let stopped = CallCoordinator(voice: OpeningVoice(), external: ExternalCallClient(credentials: credentials, configuration: configuration))
            stopped.onSaveRecord = { _ in }
            await stopped.start(role: role, connections: [connector, stt, tts], retention: AudioRetention(), historyRecords: [pendingHangup])
            precondition(f.lock.withLock { f.createRequests } == 3 && stopped.record?.id != callID,
                         "A pending explicit hangup must never be undone by automatic recovery")
            print("PASS: redial preserves explicit hangups and contact boundaries")
            return
        }
        await call.start(role: role, connections: [], retention: AudioRetention())
        precondition(call.errorMessage != nil && !call.isCallActive)
        // Answer already returns the authenticated call identity. An event
        // subscription must not add another network dependency before acceptance.
        f.lock.withLock { f.failNextEvents = true }
        try await call.prepareIncoming(callID:callID, role:role, connector:connector, connections:[connector,stt,tts], retention:AudioRetention())
        try await call.confirmIncoming(callID: callID)
        precondition(f.lock.withLock { f.failNextEvents }, "Accepting must not wait for a preliminary event request")
        f.lock.withLock { f.failNextEvents = false }
        precondition(call.phase == .connecting && call.errorMessage == nil,
                     "A new incoming call must not display the previous call's error while connecting")
        // Use the normal in-app incoming-answer path, with no user input.
        try await call.activatePreparedIncoming(callID:callID)
        try await until { voice.finished }
        precondition(voice.beginCount == 1 && voice.appended == "Hello there.")
        precondition(call.record?.messages.count == 1 && call.record?.messages.first?.role == .assistant)
        precondition(call.record?.messages.first?.status == .completed && call.generation == .completed)
        precondition(call.record?.externalEventCursor == 3 && call.record?.externalReplyID == f.reply)
        print("PASS: answered call plays an explicit opening without a fake user; final text only appends missing suffix")
        if CommandLine.arguments.contains("--network-recovery-only") {
            f.lock.withLock { f.failNextEvents = true }
            try await until { call.externalConnectionLost }
            precondition(call.errorMessage != nil)
            try await until { !call.externalConnectionLost }
            precondition(call.errorMessage == nil,
                         "A recovered event request must clear its stale timeout message")
            precondition(call.phase == .active && call.record?.externalEventCursor == 3)
            f.lock.withLock { f.failNextEvents = true }
            try await until { call.externalConnectionLost }
            voice.onEvent?(.failure(voice.session!, "Synthetic audio failure"))
            try await until { !call.externalConnectionLost }
            precondition(call.errorMessage == "Synthetic audio failure",
                         "Network recovery must preserve unrelated errors")
            call.hangUp()
            try await until { f.lock.withLock { f.ended } }
            print("PASS: event timeout recovers with the same call/cursor, clears its stale error, and preserves unrelated errors")
            return
        }
        var interruptedSave = call.record!
        interruptedSave.messages[0].status = .generating
        interruptedSave.messages[0].text = "Hello"
        interruptedSave.externalEventCursor = 2
        call.hangUp()
        try await until { f.lock.withLock { f.ended } }
        print("PASS: normal hangup closes the opening call")

        f.lock.withLock { f.ended = false; f.epoch = 0 }
        let resumedVoice = OpeningVoice()
        let resumed = CallCoordinator(voice:resumedVoice, external:ExternalCallClient(credentials:credentials, configuration:configuration))
        resumed.onSaveRecord = { _ in }
        await resumed.resumeExternal(record:interruptedSave, role:role, connections:[connector,stt,tts], retention:AudioRetention())
        try await until { resumedVoice.finished }
        precondition(resumedVoice.beginCount == 1 && resumedVoice.appended == " there.")
        precondition(resumed.record?.messages.count == 1 && resumed.record?.messages.first?.text == "Hello there.")
        resumed.hangUp()
        try await until { f.lock.withLock { f.ended } }
        print("PASS: restored opening resumes its known target and only speaks newly received text")

        let nextCallID = UUID()
        f.lock.withLock { f.call = nextCallID; f.reply = UUID(); f.available = 0; f.epoch = 0; f.ended = false }
        let userVoice = OpeningVoice()
        let userFirst = CallCoordinator(voice:userVoice, external:ExternalCallClient(credentials:credentials, configuration:configuration))
        userFirst.onSaveRecord = { _ in }
        try await userFirst.prepareIncoming(callID:nextCallID, role:role, connector:connector, connections:[connector,stt,tts], retention:AudioRetention())
        try await userFirst.confirmIncoming(callID: nextCallID)
        try await userFirst.activatePreparedIncoming(callID:nextCallID)
        precondition(userFirst.sendText("Synthetic user first"))
        try await until { userFirst.record?.externalEpoch == 1 }
        f.lock.withLock { f.available = 3 }
        try await until { userFirst.record?.externalEventCursor == 3 }
        precondition(userVoice.beginCount == 1 && userVoice.appended.isEmpty)
        precondition(userFirst.record?.messages.count == 2 && userFirst.record?.messages.last?.id != f.reply)
        userFirst.hangUp()
        print("PASS: delayed opening events cannot replace or speak over a submitted user turn")

        try await until { f.lock.withLock { f.ended } }
        let model = ConnectionProfile(name: "Synthetic model", provider: .openAICompatible,
            endpoint: URL(string: "https://mcp-opening.invalid"), model: "synthetic")
        DataSharingConsent.setAllowed(true, for: model)
        defer { DataSharingConsent.setAllowed(false, for: model) }
        try credentials.write("synthetic-fixture-only", connectionID: model.id)
        defer { try? credentials.delete(connectionID: model.id) }
        var independentRole = CallRole(name: "Synthetic", modelConnectionID: model.id, sttConnectionID: stt.id, ttsConnectionID: tts.id)
        independentRole.callMode = .standalone
        let scheduledCallID = UUID()
        f.lock.withLock {
            f.call = scheduledCallID; f.available = 0; f.epoch = 0; f.ended = false
            f.source = "independent"; f.contactID = independentRole.id.uuidString
        }
        let scheduledVoice = OpeningVoice()
        let scheduled = CallCoordinator(voice: scheduledVoice,
            model: ChatCompletionClient(credentials: credentials, configuration: configuration),
            external: ExternalCallClient(credentials: credentials, configuration: configuration))
        scheduled.onSaveRecord = { _ in }
        // Ringing must start generation and silent synthesis before the answer path.
        try scheduled.prepareIncomingOpening(callID: scheduledCallID, role: independentRole,
            connections: [model, connector, stt, tts])
        try await until { scheduledVoice.prefetchedFinished }
        precondition(scheduled.record == nil && !scheduled.isCallActive && scheduledVoice.beginCount == 0)
        precondition(f.lock.withLock { f.modelRequests.count } == 1)
        try await scheduled.prepareIncoming(callID: scheduledCallID, role: independentRole, connector: connector,
            connections: [model, connector, stt, tts], retention: AudioRetention())
        try await scheduled.confirmIncoming(callID: scheduledCallID)
        try await scheduled.activatePreparedIncoming(callID: scheduledCallID)
        try await until { scheduledVoice.finished || scheduled.generation == .failed }
        precondition(scheduled.generation == .completed && scheduledVoice.appended == "Hello from scheduled call.")
        precondition(scheduled.record?.messages.count == 1 && scheduled.record?.messages.first?.role == .assistant,
            "The call lifecycle event must not become a fabricated user utterance")
        let openingRequest = f.lock.withLock { f.modelRequests[0] }
        precondition(openingRequest.contains { ($0["role"] as? String) == "system" && ($0["content"] as? String)?.contains("主动") == true })
        precondition((openingRequest.last?["content"] as? String)?.contains("<call_event>") == true)
        precondition(f.lock.withLock { f.modelRequests.count } == 1, "Answering must use the prefetched model response")
        print("PASS: scheduled standalone answer generates and speaks first, with proactive-call context and no fabricated user record")
        scheduled.hangUp()
        try await until { f.lock.withLock { f.ended } }

        let streamingID = UUID()
        f.lock.withLock { f.call = streamingID; f.ended = false; f.epoch = 0; f.holdModel = true }
        let streamingVoice = OpeningVoice()
        let streaming = CallCoordinator(voice: streamingVoice,
            model: ChatCompletionClient(credentials: credentials, configuration: configuration),
            external: ExternalCallClient(credentials: credentials, configuration: configuration))
        streaming.onSaveRecord = { _ in }
        try streaming.prepareIncomingOpening(callID: streamingID, role: independentRole, connections: [model, connector, stt, tts])
        try await until { streamingVoice.appended == "Hello from" }
        try await streaming.prepareIncoming(callID: streamingID, role: independentRole, connector: connector,
            connections: [model, connector, stt, tts], retention: AudioRetention())
        try await streaming.confirmIncoming(callID: streamingID)
        try await streaming.activatePreparedIncoming(callID: streamingID)
        precondition(streamingVoice.beginCount == 1 && !streamingVoice.finished)
        let held = f.lock.withLock { let value = f.heldModel; f.heldModel = nil; return value }
        held!.finishModel()
        try await until { streamingVoice.finished }
        precondition(streamingVoice.appended == "Hello from scheduled call.")
        precondition(streaming.record?.messages.first?.text == streamingVoice.appended)
        precondition(f.lock.withLock { f.modelRequests.count } == 2)
        streaming.hangUp()
        try await until { f.lock.withLock { f.ended } }
        print("PASS: answering during generation continues the same stream without duplicate synthesis")

        let cancelledID = UUID()
        let cancelledVoice = OpeningVoice()
        let cancelled = CallCoordinator(voice: cancelledVoice,
            model: ChatCompletionClient(credentials: credentials, configuration: configuration))
        try cancelled.prepareIncomingOpening(callID: cancelledID, role: independentRole, connections: [model, stt, tts])
        try await until { cancelledVoice.appended == "Hello from" }
        let beforeCancel = f.lock.withLock { f.cancelledModels }
        cancelled.cancelIncomingOpening(callID: cancelledID)
        try await until { f.lock.withLock { f.cancelledModels > beforeCancel } }
        precondition(cancelledVoice.interrupted != nil && cancelledVoice.beginCount == 0)
        precondition(cancelled.record == nil && !cancelled.isCallActive)
        print("PASS: cancelling ringing stops the real model transport and silent audio preparation")
    }
}
