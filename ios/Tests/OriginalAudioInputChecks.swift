// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

private final class AudioInputProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [Data] = []
    static var requests: [Data] { lock.withLock { bodies } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "audio-input.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0, "Synthetic request body could not be read")
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        precondition(!body.isEmpty)
        Self.lock.withLock { Self.bodies.append(body) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic reply\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor private final class AudioInputVoice: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    var session: VoiceSessionID?
    var connection: ConnectionProfile?
    var switches = 0
    var failsSwitch = false
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws {
        self.session = session; connection = configuration.stt
    }
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws {
        switches += 1
        if failsSwitch { throw TincallError(message: "Synthetic switch failure") }
        self.connection = connection
    }
    func setMicrophoneMuted(_ muted: Bool) async throws { }
    func setSpeakerEnabled(_ enabled: Bool) async throws { }
    func setTextInputActive(_ active: Bool) { }
    func setSpeechInterruptionEnabled(_ enabled: Bool) { }
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws { preconditionFailure("Unexpected preparation") }
    func beginReply(_ turn: VoiceTurnID) throws { }
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws { }
    func finishReply(_ turn: VoiceTurnID) throws { onEvent?(.playback(turn, .drained)) }
    func interruptReply(_ turn: VoiceTurnID) { onEvent?(.playback(turn, .idle)) }
    func stop() { }
    func say(_ text: String, audio: Data? = nil, final: Bool = true, inputID: UUID = UUID()) {
        onEvent?(.transcript(session!, TranscriptResult(inputID: inputID, text: text, isFinal: final, audio: audio)))
    }
}

@main struct OriginalAudioInputChecks {
    @MainActor private static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for synthetic call")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let model = ConnectionProfile(name: "Synthetic model", provider: .openAICompatible,
            endpoint: URL(string: "https://audio-input.invalid"), model: "synthetic")
        let stt = ConnectionProfile(name: "Synthetic text STT", provider: .whisperCompatible,
            endpoint: URL(string: "https://synthetic.invalid"), model: "synthetic")
        let tts = ConnectionProfile(name: "Synthetic TTS", provider: .elevenLabs, model: "eleven_v3", voiceID: "synthetic")
        for connection in [model, tts] { try credentials.write("synthetic-audio-key", connectionID: connection.id) }
        defer { for connection in [model, tts] { try? credentials.delete(connectionID: connection.id) } }
        let connections = [model, stt, tts] // No saved Apple preset is required.
        for connection in connections { DataSharingConsent.setAllowed(true, for: connection) }
        defer { for connection in connections { DataSharingConsent.setAllowed(false, for: connection) } }
        let role = CallRole(name: "Synthetic", modelConnectionID: model.id, sttConnectionID: stt.id, ttsConnectionID: tts.id)
        let voice = AudioInputVoice()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioInputProtocol.self]
        let call = CallCoordinator(voice: voice, model: ChatCompletionClient(credentials: credentials, configuration: configuration))
        var failsSave = false
        call.onSaveRecord = { _ in if failsSave { throw TincallError(message: "Synthetic save failure") } }
        var savedDefaults: [UUID] = []
        call.onSpeechRecognitionUsed = { savedDefaults.append($0) }
        await call.start(role: role, connections: connections, retention: AudioRetention())
        precondition(call.phase == .active && call.supportsOriginalAudioInput)

        let initialInput = UUID()
        voice.say("First text", final: false, inputID: initialInput)
        call.requestOriginalAudioInput(true, connections: connections)
        precondition(!call.originalAudioInputEnabled && call.pendingOriginalAudioInputEnabled == true && voice.switches == 0)
        voice.say("First text", inputID: initialInput)
        try await until { call.originalAudioInputEnabled && call.generation == .completed }
        precondition(voice.connection?.provider == .appleSpeech && savedDefaults.isEmpty)
        let wave = PCM16Wave.data(pcm: Data(repeating: 0x23, count: 32_000), sampleRate: 16_000)
        let compressed = try OriginalAudioEncoder.mp3(wave: wave)
        voice.say("Second local caption", audio: wave)
        try await until { call.generation == .completed }
        let second = String(decoding: AudioInputProtocol.requests[1], as: UTF8.self)
        precondition(second.contains("First text") && second.contains("input_audio") && !second.contains("Second local caption"))
        let secondObject = try JSONSerialization.jsonObject(with: AudioInputProtocol.requests[1]) as! [String: Any]
        let secondMessages = secondObject["messages"] as! [[String: Any]]
        let secondParts = secondMessages.last!["content"] as! [[String: Any]]
        let secondAudio = secondParts.last!["input_audio"] as! [String: Any]
        precondition(secondAudio["format"] as? String == "mp3" && secondAudio["data"] as? String == compressed.base64EncodedString())
        precondition(!second.contains(wave.base64EncodedString()))
        precondition(call.record?.messages.contains { $0.text == "Second local caption" } == true && call.record?.audioAssets.isEmpty == true)
        let nextWave = PCM16Wave.data(pcm: Data(repeating: 0x45, count: 32_000), sampleRate: 16_000)
        let nextCompressed = try OriginalAudioEncoder.mp3(wave: nextWave)
        voice.say("Third local caption", audio: nextWave)
        try await until { call.generation == .completed }
        let third = String(decoding: AudioInputProtocol.requests[2], as: UTF8.self)
        precondition(third.contains("Second local caption") && !third.contains(compressed.base64EncodedString()))
        precondition(third.contains(nextCompressed.base64EncodedString()) && !third.contains("Third local caption"))
        precondition(call.sendText("Typed input stays text"))
        try await until { call.generation == .completed }
        let typed = String(decoding: AudioInputProtocol.requests[3], as: UTF8.self)
        precondition(typed.contains("Typed input stays text") && !typed.contains("input_audio"))

        voice.failsSwitch = true
        call.requestOriginalAudioInput(false, connections: connections)
        try await until { !call.isSwitchingSpeechRecognition }
        precondition(call.originalAudioInputEnabled && call.speechRecognitionError != nil && voice.connection?.provider == .appleSpeech)
        voice.failsSwitch = false
        call.requestOriginalAudioInput(false, connections: connections)
        try await until { !call.isSwitchingSpeechRecognition }
        precondition(!call.originalAudioInputEnabled && voice.connection?.id == stt.id && savedDefaults.isEmpty)
        call.requestOriginalAudioInput(true, connections: connections)
        try await until { call.originalAudioInputEnabled }

        failsSave = true
        voice.say("Save retry caption", audio: wave)
        precondition(!call.savingCallIDs.isEmpty)
        failsSave = false
        call.retrySaving()
        try await until { call.generation == .completed }
        precondition(String(decoding: AudioInputProtocol.requests.last!, as: UTF8.self).contains(compressed.base64EncodedString()))
        let count = AudioInputProtocol.requests.count
        voice.say("Missing recording must not become text")
        try await until { call.generation == .failed }
        precondition(AudioInputProtocol.requests.count == count && call.errorMessage != nil)
        voice.say("Invalid recording must not become mislabeled MP3", audio: Data(repeating: 0, count: 100))
        try await until { call.generation == .failed }
        precondition(AudioInputProtocol.requests.count == count && call.errorMessage != nil)
        call.hangUp()
        precondition(!call.originalAudioInputEnabled)
        voice.say("Late audio", audio: wave)
        precondition(AudioInputProtocol.requests.count == count)
        print("PASS: safe mode switching, Apple fallback, current audio/text history, typed input, retention off, failed-switch rollback, save retry, missing audio and late callback guards")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallSTTPersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalConfigurationStore(directory: directory)
        let apple = ConnectionProfile(name: "Synthetic Apple STT", provider: .appleSpeech)
        for connection in connections + [apple] { try store.saveConnection(connection) }
        try store.saveRole(role)
        try store.saveDefaultSTTConnection(stt.id)
        call.onSpeechRecognitionUsed = { try store.saveDefaultSTTConnection($0) }
        await call.start(role: role, connections: store.connections, retention: AudioRetention())
        voice.failsSwitch = true
        call.requestSpeechRecognitionConnection(apple)
        try await until { !call.isSwitchingSpeechRecognition }
        precondition(store.defaultSTTConnectionID == stt.id && call.speechRecognitionConnectionID == stt.id)
        voice.failsSwitch = false
        call.requestSpeechRecognitionConnection(apple)
        try await until { !call.isSwitchingSpeechRecognition }
        precondition(store.defaultSTTConnectionID == apple.id && call.speechRecognitionConnectionID == apple.id)
        call.hangUp()
        let reopened = try LocalConfigurationStore(directory: directory)
        precondition(reopened.defaultSTTConnectionID == apple.id,
                     "A successful in-call STT selection must remain the default after reopening configuration")
        print("PASS: successful in-call STT selection persists across hangup and configuration reload; failed switching preserves the previous default")
    }
}
