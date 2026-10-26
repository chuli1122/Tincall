// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class EndingModelProtocol: URLProtocol, @unchecked Sendable {
    final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var text = "再见。\n<end_call/>"
        var fails = false
    }
    static let fixture = Fixture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "call-ending.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (text, fails) = Self.fixture.lock.withLock { (Self.fixture.text, Self.fixture.fails) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        for character in text {
            let object: [String: Any] = ["choices": [["delta": ["content": String(character)]]]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            client?.urlProtocol(self, didLoad: Data("data: \(json)\n\n".utf8))
        }
        if fails { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

@MainActor private final class EndingVoice: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    var session: VoiceSessionID?
    var turn: VoiceTurnID?
    var text = ""
    var finished = false
    var stopped = false
    var emitsPlayback = true
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws { self.session = session }
    func setMicrophoneMuted(_ muted: Bool) async throws { }
    func setSpeakerEnabled(_ enabled: Bool) async throws { }
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws { }
    func setTextInputActive(_ active: Bool) { }
    func setSpeechInterruptionEnabled(_ enabled: Bool) { }
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws { preconditionFailure("Unexpected incoming preparation") }
    func beginReply(_ turn: VoiceTurnID) throws { self.turn = turn; text = ""; finished = false }
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws {
        text += delta
        if emitsPlayback { onEvent?(.playback(turn, .playing)) }
    }
    func finishReply(_ turn: VoiceTurnID) throws {
        finished = true
        if text.isEmpty { onEvent?(.playback(turn, .drained)) }
    }
    func interruptReply(_ turn: VoiceTurnID) { onEvent?(.playback(turn, .idle)) }
    func stop() { stopped = true }
}

@main struct ModelHangUpChecks {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for synthetic model")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let model = ConnectionProfile(name: "Synthetic", provider: .openAICompatible, endpoint: URL(string: "https://call-ending.invalid"), model: "synthetic")
        let stt = ConnectionProfile(name: "Synthetic STT", provider: .appleSpeech)
        let tts = ConnectionProfile(name: "Synthetic TTS", provider: .elevenLabs, model: "eleven_v3", voiceID: "synthetic")
        for connection in [model, tts] { DataSharingConsent.setAllowed(true, for: connection) }
        defer { for connection in [model, tts] { DataSharingConsent.setAllowed(false, for: connection) } }
        for connection in [model, tts] { try credentials.write("synthetic-test-key", connectionID: connection.id) }
        defer { for connection in [model, tts] { try? credentials.delete(connectionID: connection.id) } }
        let role = CallRole(name: "Synthetic", modelConnectionID: model.id, sttConnectionID: stt.id, ttsConnectionID: tts.id)
        func make(textOnly: Bool = false, silentPlayback: Bool = false) async -> (CallCoordinator, EndingVoice) {
            let voice = EndingVoice()
            voice.emitsPlayback = !silentPlayback
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EndingModelProtocol.self]
            let coordinator = CallCoordinator(voice: voice, model: ChatCompletionClient(credentials: credentials, configuration: configuration))
            coordinator.onSaveRecord = { _ in }
            await coordinator.start(role: role, connections: [model, stt, tts], retention: AudioRetention(), textOnly: textOnly)
            precondition(coordinator.isCallActive, coordinator.errorMessage ?? "Synthetic call failed to start")
            precondition(coordinator.sendText("Synthetic input"))
            return (coordinator, voice)
        }

        let (call, voice) = await make()
        try await until { voice.finished || call.generation == .failed }
        precondition(call.generation == .completed && call.isCallActive && voice.text == "再见。", "Synthetic model: \(call.generation), active=\(call.isCallActive), text=\(voice.text), error=\(call.errorMessage ?? "none")")
        precondition(call.record?.messages.last?.text == "再见。")
        voice.onEvent?(.playback(voice.turn!, .drained))
        precondition(!call.isCallActive && voice.stopped && call.record?.endedAt != nil && call.endedByRemote)
        precondition(call.record?.messages.last?.status == .completed && call.record?.messages.last?.interruption == nil)
        print("PASS: streamed command stays out of text/speech; goodbye drains before normal hangup")

        let (interrupted, interruptedVoice) = await make()
        try await until { interruptedVoice.finished }
        let oldTurn = interruptedVoice.turn!
        interrupted.interrupt()
        interruptedVoice.onEvent?(.playback(oldTurn, .drained))
        precondition(interrupted.isCallActive)
        interrupted.hangUp()
        precondition(!interrupted.endedByRemote)
        print("PASS: interruption revokes pending hangup and ignores stale playback")

        let (speaking, speakingVoice) = await make()
        try await until { speakingVoice.finished }
        speakingVoice.onEvent?(.speechActivity(speakingVoice.session!, true))
        speakingVoice.onEvent?(.playback(speakingVoice.turn!, .drained))
        precondition(speaking.isCallActive)
        speaking.hangUp()
        print("PASS: new speech prevents an old reply from hanging up")

        let (failedAudio, failedVoice) = await make()
        try await until { failedVoice.finished }
        failedVoice.onEvent?(.playback(failedVoice.turn!, .failed))
        failedVoice.onEvent?(.playback(failedVoice.turn!, .drained))
        precondition(failedAudio.isCallActive)
        failedAudio.hangUp()
        print("PASS: failed audio does not claim a completed farewell or hang up")

        let (silentPlayback, silentVoice) = await make(silentPlayback: true)
        try await until { silentVoice.finished }
        precondition(silentPlayback.generation == .completed && silentPlayback.playback == .synthesizing)
        silentPlayback.hangUp()
        precondition(silentPlayback.record?.messages.last?.status == .completed &&
                     silentPlayback.record?.messages.last?.interruption == nil,
                     "silent synthesized reply was incorrectly marked interrupted")
        print("PASS: hangup before the first playback callback keeps a completed reply clean")

        let (textCall, _) = await make(textOnly: true)
        try await until { !textCall.isCallActive || textCall.generation == .failed }
        precondition(textCall.phase == .ended && textCall.record?.messages.last?.text == "再见。")
        print("PASS: text-only standalone call ends without waiting for audio")

        EndingModelProtocol.fixture.lock.withLock { EndingModelProtocol.fixture.text = "<end_call/>" }
        let (empty, emptyVoice) = await make()
        try await until { !empty.isCallActive || empty.generation == .failed }
        precondition(empty.phase == .ended && emptyVoice.text.isEmpty)
        print("PASS: command-only response drains synchronously without getting stuck")

        EndingModelProtocol.fixture.lock.withLock {
            EndingModelProtocol.fixture.text = "再见。\n<end_call/>"
            EndingModelProtocol.fixture.fails = true
        }
        let (failedStream, failedStreamVoice) = await make()
        try await until { failedStream.generation == .failed }
        precondition(failedStream.isCallActive && !failedStreamVoice.text.contains("end_call"))
        failedStream.hangUp()
        print("PASS: failed generation never executes its buffered hangup command")
    }
}
