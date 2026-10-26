// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

@MainActor private final class ControlVoice: VoiceService {
    var onEvent: ((VoiceEvent) -> Void)?
    var session: VoiceSessionID?
    var muteRequests: [Bool] = []
    var speakerRequests: [Bool] = []
    var failsRouting = false
    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws {
        self.session = session
        onEvent?(.speakerState(session, true))
    }
    func setMicrophoneMuted(_ muted: Bool) async throws { muteRequests.append(muted) }
    func setSpeakerEnabled(_ enabled: Bool) throws {
        if failsRouting { throw TincallError(message: "Synthetic route failure") }
        speakerRequests.append(enabled)
        if let session { onEvent?(.speakerState(session, enabled)) }
    }
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws { preconditionFailure("unexpected recognition switch") }
    func setTextInputActive(_ active: Bool) {}
    func setSpeechInterruptionEnabled(_ enabled: Bool) {}
    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws { preconditionFailure("Unexpected incoming preparation") }
    func beginReply(_ turn: VoiceTurnID) throws { preconditionFailure("no synthesis in control check") }
    func appendReply(_ delta: String, to turn: VoiceTurnID) throws { preconditionFailure("no synthesis in control check") }
    func finishReply(_ turn: VoiceTurnID) throws { preconditionFailure("no synthesis in control check") }
    func interruptReply(_ turn: VoiceTurnID) {}
    func stop() {}
}

@main struct CallAudioControlChecks {
    @MainActor static func main() async throws {
        let credentials = CredentialStore()
        let model = ConnectionProfile(name: "Synthetic model", provider: .openAICompatible,
                                      endpoint: URL(string: "https://synthetic.invalid"), model: "synthetic")
        let stt = ConnectionProfile(name: "Synthetic STT", provider: .appleSpeech)
        let tts = ConnectionProfile(name: "Synthetic TTS", provider: .elevenLabs, model: "eleven_v4", voiceID: "synthetic")
        for connection in [model, tts] { DataSharingConsent.setAllowed(true, for: connection) }
        defer { for connection in [model, tts] { DataSharingConsent.setAllowed(false, for: connection) } }
        try credentials.write("synthetic-control-key", connectionID: model.id)
        try credentials.write("synthetic-control-key", connectionID: tts.id)
        defer {
            try? credentials.delete(connectionID: model.id)
            try? credentials.delete(connectionID: tts.id)
        }
        let role = CallRole(name: "Synthetic", modelConnectionID: model.id, sttConnectionID: stt.id, ttsConnectionID: tts.id)
        let voice = ControlVoice()
        let coordinator = CallCoordinator(voice: voice)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincall-audio-controls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = try CallRecordStore(directory: directory)
        coordinator.onSaveRecord = { try records.save($0) }
        await coordinator.start(role: role, connections: [model, stt, tts], retention: AudioRetention())
        precondition(coordinator.phase == .active && coordinator.isSpeakerEnabled)
        await coordinator.toggleMute()
        precondition(coordinator.isMuted && coordinator.isSpeakerEnabled && voice.speakerRequests.isEmpty)
        await coordinator.toggleSpeaker()
        precondition(coordinator.isMuted && !coordinator.isSpeakerEnabled && voice.muteRequests == [true])
        await coordinator.toggleMute()
        precondition(!coordinator.isMuted && !coordinator.isSpeakerEnabled && voice.speakerRequests == [false])
        voice.failsRouting = true
        await coordinator.toggleSpeaker()
        precondition(!coordinator.isSpeakerEnabled && !coordinator.isMuted && coordinator.errorMessage == "Synthetic route failure")
        voice.failsRouting = false
        voice.onEvent?(.speakerState(VoiceSessionID(callID: UUID(), epoch: UUID()), true))
        precondition(!coordinator.isSpeakerEnabled, "stale route events cannot change the current call")
        coordinator.hangUp()
        let requests = voice.speakerRequests
        await coordinator.toggleSpeaker()
        precondition(voice.speakerRequests == requests, "ended calls cannot change output")
        print("PASS: microphone and speaker controls remain independent; actual/stale route reports, failure and hangup guards")
    }
}
