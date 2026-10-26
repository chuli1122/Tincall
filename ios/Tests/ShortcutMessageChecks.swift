// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

/// A text-only operation must never touch any audio API, including stop or interrupt.
@MainActor private final class ForbiddenShortcutAudio: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws { preconditionFailure("audio start") }
    func setMicrophoneMuted(_ muted: Bool) async throws { preconditionFailure("microphone") }
    func setSpeakerEnabled(_ enabled: Bool) throws { preconditionFailure("speaker routing") }
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws { preconditionFailure("recognition switch") }
    func setTextInputActive(_ active: Bool) { preconditionFailure("audio input") }
    func setSpeechInterruptionEnabled(_ enabled: Bool) { preconditionFailure("audio interruption") }
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws { preconditionFailure("Unexpected incoming preparation") }
    func beginReply(_ turn: VoiceTurnID) throws { preconditionFailure("synthesis start") }
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws { preconditionFailure("synthesis delta") }
    func finishReply(_ turn: VoiceTurnID) throws { preconditionFailure("synthesis finish") }
    func interruptReply(_ turn: VoiceTurnID) { preconditionFailure("synthesis interrupt") }
    func stop() { preconditionFailure("audio stop") }
}

private final class ShortcutConnectorProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = Fixture()
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var callID = UUID()
        var inputID: String?
        var replyID = UUID().uuidString
        var source = ""
        var allowCompletion = false
        var ended = false
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "shortcut-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
        let body = data.isEmpty ? [:] : try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload: [String: Any] = Self.fixture.lock.withLock {
            let fixture = Self.fixture
            switch request.url!.lastPathComponent {
            case "calls":
                fixture.callID = UUID(uuidString: body["call_id"] as! String)!
                fixture.source = body["source"] as! String
                fixture.inputID = nil; fixture.allowCompletion = false; fixture.ended = false
                precondition(body["expression_prompt"] as? String == "")
            case "input":
                fixture.inputID = body["message_id"] as? String
                precondition(body["text"] as? String == "Synthetic shortcut input")
                let images = body["images"] as! [[String: Any]]
                precondition(images.count == 1 && images[0]["data_base64"] as? String == "/9j/2Q==")
            case "end": fixture.ended = true
            default: precondition(request.url!.lastPathComponent == "events")
            }
            let call: [String: Any] = ["id": fixture.callID.uuidString, "contact_id": "fixture-contact",
                "source": fixture.source, "status": fixture.ended ? "ended" : "active",
                "epoch": fixture.inputID == nil ? 0 : 1, "last_sequence": fixture.allowCompletion ? 2 : 1]
            if request.url!.lastPathComponent == "input" {
                return ["call": call, "input_id": fixture.inputID!, "reply_id": fixture.replyID, "epoch": 1]
            }
            if request.url!.lastPathComponent != "events" { return ["call": call] }
            let after = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
            var events: [[String: Any]] = []
            if let inputID = fixture.inputID, after == 0 || (after == 1 && fixture.allowCompletion) {
                let completed = after == 1
                events = [["sequence": after + 1, "call_id": fixture.callID.uuidString, "epoch": 1,
                    "type": completed ? "reply.completed" : "reply.delta",
                    "payload": ["input_id": inputID, "reply_id": fixture.replyID,
                        completed ? "text" : "delta": completed ? "Synthetic late reply" : "Synthetic late "]]]
            }
            return ["call": call, "events": events, "cursor": after + events.count, "has_more": false]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ShortcutMessageChecks {
    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        precondition(predicate(), "timed out waiting for fixture")
    }

    @MainActor static func main() async throws {
        do {
            _ = try TincallShortcutMessages.activeCall(nil)
            preconditionFailure("a shortcut without a call must not start a conversation")
        } catch let error as TincallError {
            precondition(error.message == "当前没有正在进行的通话，请先在 Tincall 中开始通话")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincall-shortcut-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = try CallRecordStore(directory: directory)
        let credentials = CredentialStore()
        let model = ConnectionProfile(name: "Fixture model", provider: .openAICompatible,
            endpoint: URL(string: "https://shortcut-fixture.invalid"), model: "fixture")
        let connector = ConnectionProfile(name: "Fixture connector", provider: .genericConnector,
            endpoint: URL(string: "https://shortcut-fixture.invalid"))
        for connection in [model, connector] { DataSharingConsent.setAllowed(true, for: connection) }
        defer { for connection in [model, connector] { DataSharingConsent.setAllowed(false, for: connection) } }
        for connection in [model, connector] { try credentials.write("synthetic-shortcut-token", connectionID: connection.id) }
        defer { for connection in [model, connector] { try? credentials.delete(connectionID: connection.id) } }
        func coordinator() -> CallCoordinator {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ShortcutConnectorProtocol.self]
            let coordinator = CallCoordinator(voice: ForbiddenShortcutAudio(),
                external: ExternalCallClient(credentials: credentials, configuration: configuration))
            coordinator.onSaveRecord = { try records.save($0) }
            coordinator.onSaveImages = { try records.saveImages(recordID: $0, messageID: $1, images: $2) }
            coordinator.onLoadImages = { recordID, message in
                try (message.images ?? []).map { try Data(contentsOf: records.imageURL($0, recordID: recordID, messageID: message.id)) }
            }
            return coordinator
        }

        let standalone = coordinator()
        var role = CallRole(name: "Fixture", modelConnectionID: model.id, contextCharacterBudget: 1_000)
        precondition(standalone.configurationIssue(role: role, connections: [model])?.contains("识别") == true)
        await standalone.start(role: role, connections: [], retention: AudioRetention(), textOnly: true)
        precondition(standalone.errorMessage == "此联系人缺少模型连接" && records.records.isEmpty)
        await standalone.start(role: role, connections: [model], retention: AudioRetention(), textOnly: true)
        precondition(standalone.canSend)
        let originalCallID = standalone.record!.id
        let current = try TincallShortcutMessages.activeCall(standalone, expectedCallID: originalCallID.uuidString)
        precondition(current.coordinator === standalone && current.id == originalCallID)
        // An over-budget standalone message exercises the real context path without a provider request.
        precondition(standalone.sendText(String(repeating: "文", count: 1_001)))
        precondition(standalone.generation == .failed && standalone.errorMessage?.contains("预算") == true)
        standalone.hangUp()
        do {
            try TincallShortcutMessages.send(in: standalone, callID: originalCallID, text: "Do not send", images: [])
            preconditionFailure("hanging up while entering text must prevent sending")
        } catch let error as TincallError {
            precondition(error.message == "当前没有正在进行的通话，请先在 Tincall 中开始通话")
        }
        let restoredStandalone = try CallRecordStore(directory: directory)
        precondition(restoredStandalone.records.first?.messages.count == 2)

        for mode in [CallMode.mcp, .backend] {
            role.callMode = mode; role.externalConnectionID = connector.id; role.externalRoleID = "fixture-contact"
            let operation = coordinator()
            await operation.start(role: role, connections: [connector], retention: AudioRetention(), textOnly: true)
            precondition(operation.canSend)
            do {
                try TincallShortcutMessages.send(in: operation, callID: originalCallID, text: "Wrong call", images: [])
                preconditionFailure("a stale shortcut must not send into a new call")
            } catch let error as TincallError {
                precondition(error.message == "原通话已结束，请重新运行快捷指令")
            }
            precondition(operation.record!.messages.isEmpty)
            try TincallShortcutMessages.send(in: operation, callID: operation.record!.id,
                text: "Synthetic shortcut input", images: [Data([0xff, 0xd8, 0xff, 0xd9])])
            precondition(operation.isCallActive && operation.generation == .generating,
                "shortcut returns immediately while the runtime keeps the call reply running")
            try await waitUntil { operation.record?.messages.last?.text == "Synthetic late " }
            do {
                try TincallShortcutMessages.send(in: operation, callID: operation.record!.id,
                    text: "Do not interrupt", images: [])
                preconditionFailure("a shortcut must leave an ongoing reply alone")
            } catch let error as TincallError {
                precondition(error.message == "TA 正在回复或说话，请稍后再发送")
            }
            let saved = try CallRecordStore(directory: directory).records.first { $0.id == operation.record!.id }!
            precondition(saved.roleID == role.id && saved.callMode == mode && saved.messages.count == 2)
            precondition(saved.messages.last?.status == .generating && saved.messages.last?.text == "Synthetic late ")
            let metadata = RequestLogStore.shared.entries.first {
                $0.context?.callID == saved.id && $0.step == .model
            }!
            let logged = try RequestLogStore.shared.load([metadata])[0]
            precondition(logged.requestText?.contains("[图片 1：image/jpeg，4 字节]") == true)
            let original = try JSONSerialization.jsonObject(with: Data(logged.requestBodyJSON!.utf8)) as! [String: Any]
            precondition((original["images"] as! [[String: Any]])[0]["data_base64"] as? String == "/9j/2Q==")
            precondition(RequestLogText.export([logged]).contains(logged.requestBodyJSON!))
            // Returning to a shortcut's caller must not hang up or cancel this still-running operation.
            precondition(operation.generation == .generating)
            ShortcutConnectorProtocol.fixture.lock.withLock { ShortcutConnectorProtocol.fixture.allowCompletion = true }
            try await waitUntil { operation.generation == .completed }
            precondition(operation.record?.messages.last?.text == "Synthetic late reply" && operation.isCallActive)
            operation.hangUp()
            try await waitUntil { operation.record?.externalPendingControl == nil }
            let restored = try CallRecordStore(directory: directory).records.first { $0.id == saved.id }!
            precondition(restored.messages.last?.text == "Synthetic late reply" && restored.messages.last?.status == .completed)
            precondition(restored.endedAt != nil && restored.audioAssets.isEmpty)
        }
        print("PASS: no-call warning, hangup/new-call rejection, current-call routing, busy-reply protection, immediate shortcut completion, MCP/backend late replies and persistence; no audio APIs")
    }
}
