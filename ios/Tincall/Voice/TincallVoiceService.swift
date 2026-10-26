// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import Foundation
import OSLog

@MainActor
final class TincallVoiceService: VoiceService {
    private let logger = Logger(subsystem: "com.tincall.app", category: "VoiceCallSession")
    var onEvent: ((VoiceEvent) -> Void)?
    private let credentials: CredentialStore
    private var playback = SpeechPlayback()
    private var incomingReply: (turn: VoiceTurnID, playback: SpeechPlayback)?
    private var session: VoiceSessionID?
    private var configuration: VoiceConfiguration?
    private var ttsConfiguration: SpeechSynthesisConfiguration?
    private var recognizer: (any SpeechRecognizer)?
    private var recognitionSwitchID: UUID?
    private var inputID = UUID()
    private var finalInputID: UUID?
    private var hasPartialTranscript = false
    private var turn: VoiceTurnID?
    private var playbackTask: Task<Void, Never>?
    private var microphoneMuted = false
    private var speakerOverride: Bool?
    private let audioRouting = CallAudioRouting()
    private var outputChangesInFlight = 0
    private var duckingRevision = 0
    private var replyPlaybackStarted = false
    private var userSpeechDuckingActive = false
    private var speechDuckingReleaseTask: Task<Void, Never>?
    private var requestedDucking: Bool? = false
    private var bluetoothRefreshTask: Task<Void, Never>?
    private var bluetoothRepairFailed = false
    private var pendingAutomaticOutput = false
    private var textInputActive = false
    private var audioInterrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var speechInterruptionEnabled = true
    private var transcriptionPaused = false
    private var preparingIncomingAudio = false
    private var interruptionAvailability: SpeechInterruptionAvailability?
    private var backgroundEngine: AVAudioEngine?
    private var backgroundObservationID = UUID()
    private var backgroundPlayer: AVAudioPlayerNode?
    private var backgroundBuffer: AVAudioPCMBuffer?
    private var backgroundConfigurationObserver: NSObjectProtocol?

    init(credentials: CredentialStore = CredentialStore()) { self.credentials = credentials }

    func start(session: VoiceSessionID, configuration: VoiceConfiguration) async throws {
        if preparingIncomingAudio, self.session == session {
            guard recognizer != nil, !audioInterrupted else { throw CancellationError() }
            preparingIncomingAudio = false
            updateRecognitionPolicy()
            if let turn = incomingReply?.turn { try beginReply(turn) }
            return
        }
        try await startAudio(session: session, configuration: configuration, preparingIncoming: false)
    }

    /// Acquire the actual microphone under CallKit while cloud acceptance is
    /// pending. Transcription and buffered reply playback wait for start().
    func prepareIncomingAudio(session: VoiceSessionID, configuration: VoiceConfiguration) async throws {
        try await startAudio(session: session, configuration: configuration, preparingIncoming: true)
    }

    private func startAudio(session: VoiceSessionID, configuration: VoiceConfiguration,
                            preparingIncoming: Bool) async throws {
        let preparedReply = incomingReply?.turn.session == session ? incomingReply : nil
        if preparedReply == nil { incomingReply?.playback.stop() }
        incomingReply = nil
        stop()
        incomingReply = preparedReply
        preparingIncomingAudio = preparingIncoming
        guard configuration.stt.provider.isSpeechRecognition, configuration.tts.provider.isSpeechSynthesis else {
            throw TincallError(message: String(localized: "请选择受支持的语音识别和合成连接"))
        }
        guard (configuration.stt.provider == .whisperCompatible || configuration.stt.endpoint == nil), configuration.tts.endpoint == nil else {
            throw TincallError(message: String(localized: "语音服务使用所选地区的官方地址，不支持自定义端点"))
        }
        ttsConfiguration = try makeSynthesisConfiguration(configuration)
        self.session = session
        self.configuration = configuration
        microphoneMuted = false
        var permission = AVAudioApplication.shared.recordPermission == .granted
        if !permission { permission = await AVAudioApplication.requestRecordPermission() }
        guard self.session == session else { throw CancellationError() }
        guard permission else { stop(); throw TincallError(message: String(localized: "请允许 Tincall 使用麦克风")) }
        do {
            try await startIndependentAudio()
            observeInterruptions()
            observeRouteChanges(session: session)
            if !preparingIncoming, let turn = incomingReply?.turn { try beginReply(turn) }
            try await startRecognition()
        } catch {
            guard self.session == session else { throw CancellationError() }
            MicrophoneCapture.recordDiagnostic(.microphoneFailed, phase: "service_start", error: error)
            stop()
            throw Self.safeError(error)
        }
    }

    /// CallKit has relinquished an incoming call. Reacquire media explicitly in
    /// either app state; system deactivation can stop both graphs.
    func resumeAfterSystemAudioHandoff() async throws {
        guard let identity = session else { throw CancellationError() }
        beginOutputChange()
        defer { endOutputChange(session: identity) }
        let previousRecognizer = recognizer
        recognizer = nil
        await previousRecognizer?.stopAndWait()
        guard session == identity else { throw CancellationError() }
        do {
            try await audioRouting.activate(session: identity)
            guard session == identity else { throw CancellationError() }
            audioInterrupted = false
            try await startIndependentAudio()
            playback.setAudioInterrupted(false)
            updateOtherAudioDucking()
            if !microphoneMuted { try await startRecognition() }
            guard session == identity else { throw CancellationError() }
            onEvent?(.microphoneState(identity, microphoneMuted))
        } catch {
            MicrophoneCapture.recordDiagnostic(.microphoneFailed, phase: "incoming_handoff", error: error)
            throw Self.microphoneStartError(error)
        }
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard let session else { throw TincallError(message: String(localized: "通话尚未连接")) }
        CallAudioDiagnostics.record(.microphoneChange, turn: turn?.turnID, input: inputID, flag: muted)
        microphoneMuted = muted
        if muted {
            clearCaption()
        } else if audioInterrupted || recognizer == nil {
            do {
                if audioInterrupted {
                    // An explicit retry asks the system whether audio is available;
                    // a missing interruption-ended notification must not lock the mic.
                    try await audioRouting.activate(session: session)
                    guard self.session == session else { throw CancellationError() }
                }
                try await startIndependentAudio()
                guard self.session == session else { throw CancellationError() }
                audioInterrupted = false
                playback.setAudioInterrupted(false)
                updateOtherAudioDucking()
                if recognizer == nil { try await startRecognition() }
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard self.session == session else { throw CancellationError() }
                MicrophoneCapture.recordDiagnostic(.microphoneFailed, phase: "unmute_start",
                    turn: turn?.turnID, input: inputID, error: error)
                microphoneMuted = true
                updateRecognitionPolicy()
                onEvent?(.microphoneState(session, true))
                throw Self.microphoneStartError(error)
            }
        }
        updateRecognitionPolicy()
    }

    func setSpeakerEnabled(_ enabled: Bool) async throws {
        guard let identity = session else { throw TincallError(message: String(localized: "通话尚未连接")) }
        beginOutputChange()
        defer { endOutputChange(session: identity) }
        let result = try await audioRouting.setSpeakerEnabled(enabled, session: identity)
        guard session == identity else { throw CancellationError() }
        let categoryTime = result.categoryMilliseconds.map(String.init) ?? "unfinished"
        let outputTime = result.outputMilliseconds.map(String.init) ?? "unfinished"
        MicrophoneCapture.recordDiagnostic(.speakerChange,
            phase: "\(enabled ? "on" : "off")_category_ms_\(categoryTime)_output_ms_\(outputTime)_total_ms_\(result.totalMilliseconds)_success_\(result.errorCode == nil ? 1 : 0)_main_\(result.ranOnMainThread ? 1 : 0)")
        if let code = result.rollbackErrorCode { logger.error("phase=speaker_restore_failed error_code=\(code)") }
        if let code = result.errorCode {
            reportSpeakerState()
            throw TincallError(message: String(localized: "无法切换扬声器（错误码：\(String(code))）"))
        }
        speakerOverride = enabled
        reportSpeakerState()
    }

    private func beginOutputChange() {
        outputChangesInFlight += 1
        MicrophoneCapture.outputRouteTransitionActive = true
    }

    private func endOutputChange(session identity: VoiceSessionID) {
        guard session == identity else { return }
        outputChangesInFlight = max(0, outputChangesInFlight - 1)
        guard outputChangesInFlight == 0 else { return }
        MicrophoneCapture.outputRouteTransitionActive = false
        Task { [weak self] in
            guard let self, self.session == identity, self.outputChangesInFlight == 0, !self.audioInterrupted else { return }
            await MicrophoneCapture.refreshForCurrentRoute()
            guard self.session == identity, self.outputChangesInFlight == 0, !self.audioInterrupted else { return }
            do { try await self.startIndependentAudio() }
            catch is CancellationError { }
            catch {
                MicrophoneCapture.recordDiagnostic(.independentAudioFailed, phase: "output_restore", error: error)
                self.onEvent?(.failure(identity, Self.safeError(error).message))
            }
        }
    }

    private func reportSpeakerState() {
        guard let session else { return }
        let route = AVAudioSession.sharedInstance().currentRoute
        // Ending the temporary CallKit audio session can briefly expose a
        // speaker-only route with no input. It is a handoff transition, not a
        // user-selected speaker state; publishing it makes the call button
        // flash on and then off.
        guard !route.inputs.isEmpty || !route.outputs.contains(where: { $0.portType == .builtInSpeaker }) else { return }
        let enabled = route.outputs.contains { $0.portType == .builtInSpeaker }
        onEvent?(.speakerState(session, enabled))
    }

    func setSpeechInterruptionEnabled(_ enabled: Bool) {
        speechInterruptionEnabled = enabled
        updateRecognitionPolicy()
    }

    func setTextInputActive(_ active: Bool) {
        guard session != nil, textInputActive != active else { return }
        textInputActive = active
        updateRecognitionPolicy()
        if active { clearCaption() }
    }

    private func makeSynthesisConfiguration(_ configuration: VoiceConfiguration) throws -> SpeechSynthesisConfiguration {
        try DataSharingConsent.require(configuration.tts)
        let override = configuration.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = override.isEmpty ? configuration.tts.voiceID.trimmingCharacters(in: .whitespacesAndNewlines) : override
        let model = configuration.tts.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty else { throw TincallError(message: String(localized: "请填写语音合成音色 ID")) }
        switch configuration.tts.provider {
        case .elevenLabs:
            guard !model.isEmpty, voiceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw TincallError(message: String(localized: "请填写有效的 ElevenLabs 音色和模型"))
            }
            return .elevenLabs(ElevenLabsConfiguration(elevenLabsAPIKey: try secret(configuration.tts.id),
                elevenLabsVoiceID: voiceID, elevenLabsModel: model,
                stability: configuration.tts.elevenLabsStability,
                similarityBoost: configuration.tts.elevenLabsSimilarityBoost))
        case .miniMax:
            let region = configuration.tts.region ?? "china"
            guard region == "china" || region == "international" else { throw TincallError(message: String(localized: "MiniMax 地区无效")) }
            return .miniMax(MiniMaxConfiguration(apiKey: try secret(configuration.tts.id),
                model: model.isEmpty ? "speech-02-hd" : model, voiceID: voiceID,
                endpoint: URL(string: region == "china" ? "https://api.minimax.cn/v1/t2a_v2" : "https://api.minimax.io/v1/t2a_v2")!))
        case .fishAudio:
            return .fishAudio(try FishAudioConfiguration(apiKey: secret(configuration.tts.id),
                model: model, referenceID: voiceID))
        default: throw TincallError(message: String(localized: "请选择受支持的语音合成连接"))
        }
    }

    func prepareIncomingReply(_ turn: VoiceTurnID, configuration: VoiceConfiguration) throws {
        guard session == nil else { throw CancellationError() }
        incomingReply?.playback.stop()
        let prepared = SpeechPlayback()
        prepared.retainsAudio = configuration.retention.assistant
        try prepared.begin(settings: makeSynthesisConfiguration(configuration),
            logContext: RequestLogStore.shared.context(for: turn), connectionName: configuration.tts.name,
            diagnosticTurn: turn.turnID, playbackEnabled: false)
        incomingReply = (turn, prepared)
    }

    func beginReply(_ turn: VoiceTurnID) throws {
        guard session == turn.session, let ttsConfiguration else { throw CancellationError() }
        CallAudioDiagnostics.record(.replyBegin, turn: turn.turnID, input: inputID)
        let prepared = incomingReply?.turn == turn ? incomingReply?.playback : nil
        stopReply()
        if let prepared { playback = prepared; incomingReply = nil }
        playback.retainsAudio = configuration?.retention.assistant == true
        playback.onActivityStateChange = { [weak self] active in
            guard let self, self.session == turn.session, self.turn == turn else { return }
            if !active { self.replyPlaybackStarted = false }
            self.updateOtherAudioDucking()
            self.updateRecognitionPolicy()
        }
        playback.onPlaybackStateChange = { [weak self] playing in
            guard let self, self.session == turn.session, self.turn == turn else { return }
            if playing { self.replyPlaybackStarted = true }
            self.updateOtherAudioDucking()
            self.updateRecognitionPolicy()
            self.onEvent?(.playback(turn, playing ? .playing : .synthesizing))
        }
        playback.onCaptionChange = { [weak self] caption in
            guard let self, self.session == turn.session, self.turn == turn else { return }
            self.onEvent?(.playbackCaption(turn, caption))
        }
        playback.onAudioReady = { [weak self] index, audio in
            guard let self, self.session == turn.session, self.turn == turn else { return }
            self.deliverAudio(audio, messageID: turn.messageID, segmentIndex: index, sampleRate: 24_000)
        }
        self.turn = turn
        updateRecognitionPolicy()
        onEvent?(.playback(turn, .synthesizing))
        do {
            if prepared != nil { try playback.enablePlayback() }
            else {
                try playback.begin(settings: ttsConfiguration, logContext: RequestLogStore.shared.context(for: turn),
                    connectionName: configuration?.tts.name, diagnosticTurn: turn.turnID)
            }
        } catch { throw Self.safeError(error) }
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.playback.waitUntilFinished()
                guard self.session == turn.session, self.turn == turn, !Task.isCancelled else { return }
                CallAudioDiagnostics.record(.replyDrained, turn: turn.turnID)
                self.onEvent?(.playback(turn, .drained))
            } catch is CancellationError { }
            catch {
                guard self.session == turn.session, self.turn == turn, !Task.isCancelled else { return }
                CallAudioDiagnostics.record(.replyFailed, turn: turn.turnID)
                self.onEvent?(.playback(turn, .failed))
                guard self.session == turn.session, self.turn == turn, !Task.isCancelled else { return }
                if let caption = self.playback.failedCaption, !caption.isEmpty {
                    self.onEvent?(.playbackCaption(turn, caption))
                }
                self.onEvent?(.failure(turn.session, Self.safeError(error).message))
            }
        }
    }

    func appendReply(_ delta: String, to turn: VoiceTurnID) throws {
        guard delta.count <= 65_536 else { throw TincallError(message: String(localized: "单次回复增量过大")) }
        if let incomingReply, incomingReply.turn == turn {
            try incomingReply.playback.appendText(delta, final: false)
            return
        }
        guard self.session == turn.session, self.turn == turn else { throw CancellationError() }
        do { try playback.appendText(delta, final: false) }
        catch { stopReply(); onEvent?(.playback(turn, .failed)); throw Self.safeError(error) }
    }

    func finishReply(_ turn: VoiceTurnID) throws {
        if let incomingReply, incomingReply.turn == turn {
            try incomingReply.playback.appendText("", final: true)
            return
        }
        guard self.session == turn.session, self.turn == turn else { throw CancellationError() }
        do { try playback.appendText("", final: true) }
        catch { stopReply(); onEvent?(.playback(turn, .failed)); throw Self.safeError(error) }
    }

    func interruptReply(_ turn: VoiceTurnID) {
        if incomingReply?.turn == turn {
            incomingReply?.playback.stop()
            incomingReply = nil
            return
        }
        guard self.session == turn.session, self.turn == turn else { return }
        CallAudioDiagnostics.record(.replyInterrupt, turn: turn.turnID, input: inputID)
        stopReply()
        onEvent?(.playback(turn, .idle))
    }

    func stop() {
        preparingIncomingAudio = false
        incomingReply?.playback.stop()
        incomingReply = nil
        let closingSession = session
        let partialAudio = configuration?.retention.user == true && hasPartialTranscript
            ? recognizer?.currentInputAudio : nil
        hasPartialTranscript = false
        recognizer?.stop(); recognizer = nil
        clearUserSpeechDucking()
        stopReply()
        if let partialAudio, !partialAudio.isEmpty {
            deliverAudio(SpeechPlayback.waveData(pcm: partialAudio, sampleRate: 16_000),
                         messageID: inputID, segmentIndex: 0, sampleRate: 16_000)
        }
        session = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        if let backgroundConfigurationObserver { NotificationCenter.default.removeObserver(backgroundConfigurationObserver) }
        backgroundConfigurationObserver = nil
        backgroundPlayer?.stop(); backgroundPlayer = nil
        backgroundEngine?.stop(); backgroundEngine = nil
        backgroundBuffer = nil
        configuration = nil; ttsConfiguration = nil
        recognitionSwitchID = nil
        microphoneMuted = false; audioInterrupted = false
        speakerOverride = nil
        bluetoothRefreshTask?.cancel(); bluetoothRefreshTask = nil
        bluetoothRepairFailed = false
        pendingAutomaticOutput = false
        outputChangesInFlight = 0
        duckingRevision = 0
        replyPlaybackStarted = false
        requestedDucking = false
        MicrophoneCapture.outputRouteTransitionActive = false
        textInputActive = false
        transcriptionPaused = false; interruptionAvailability = nil
        MicrophoneCapture.requiresSustainedSpeech = false
        playback.setAudioInterrupted(false)
        if let closingSession {
            Task { [audioRouting, logger] in
                if let code = await audioRouting.stop(session: closingSession) {
                    logger.error("phase=call_audio_stop_failed error_code=\(code)")
                }
            }
        }
        // audioReady transfers immutable file ownership. Stop never deletes delivered files.
    }

    private func secret(_ id: UUID, field: CredentialField = .apiKey) throws -> String {
        guard let value = try credentials.read(connectionID: id, field: field), !value.isEmpty,
              !value.contains("•"), !value.contains("*"), value != "已配置" else {
            throw TincallError(message: String(localized: "请在连接设置中保存有效的语音服务凭据"))
        }
        return value
    }

    /// Replace capture/STT only. Reply playback and the call's audio session stay alive.
    func setSpeechRecognitionConnection(_ connection: ConnectionProfile) async throws {
        guard let identity = session, let previous = configuration else { throw CancellationError() }
        guard !audioInterrupted else {
            throw TincallError(message: String(localized: "系统音频中断尚未结束，请稍后切换识别服务"))
        }
        // Validate the new credentials and provider before stopping the working recognizer.
        let candidate = try makeRecognizer(connection, session: identity)
        guard recognitionSwitchID == nil else { throw CancellationError() }
        let switchID = UUID()
        recognitionSwitchID = switchID
        defer { if recognitionSwitchID == switchID { recognitionSwitchID = nil } }
        let wasMuted = microphoneMuted
        let previousRecognizer = recognizer
        recognizer = nil
        await previousRecognizer?.stopAndWait()
        guard session == identity, !Task.isCancelled else { throw CancellationError() }
        guard !audioInterrupted else {
            throw TincallError(message: String(localized: "系统音频中断尚未结束，请稍后切换识别服务"))
        }
        clearUserSpeechDucking()
        onEvent?(.speechActivity(identity, false))
        configuration = VoiceConfiguration(stt: connection, tts: previous.tts,
            voiceID: previous.voiceID, retention: previous.retention)
        do {
            try await startRecognition(client: candidate)
            guard session == identity else { throw CancellationError() }
        } catch {
            guard session == identity else { throw CancellationError() }
            configuration = previous
            guard !audioInterrupted else {
                microphoneMuted = true
                updateRecognitionPolicy()
                onEvent?(.microphoneState(identity, true))
                throw TincallError(message: String(localized: "系统音频中断尚未结束，请稍后切换识别服务"))
            }
            microphoneMuted = wasMuted
            do {
                try await startRecognition()
                guard session == identity else { throw CancellationError() }
                onEvent?(.microphoneState(identity, wasMuted))
            } catch {
                guard session == identity else { throw CancellationError() }
                microphoneMuted = true
                updateRecognitionPolicy()
                onEvent?(.microphoneState(identity, true))
                throw TincallError(message: String(localized: "识别服务切换失败，原服务也未能恢复，请重新打开麦克风"))
            }
            throw TincallError(message: String(localized: "识别服务切换失败，已恢复原服务"))
        }
    }

    private func makeRecognizer(_ stt: ConnectionProfile, session: VoiceSessionID) throws -> any SpeechRecognizer {
        try DataSharingConsent.require(stt)
        guard stt.provider.isSpeechRecognition,
              stt.provider == .whisperCompatible || stt.endpoint == nil else {
            throw TincallError(message: String(localized: "请选择受支持的语音识别连接"))
        }
        let client: any SpeechRecognizer
        let logContext: () -> RequestLogContext? = { [weak self] in
            guard let self, self.session == session else { return nil }
            return RequestLogContext(callID: session.callID, roundID: self.inputID)
        }
        switch stt.provider {
        case .xunfei:
            let applicationID = stt.applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !applicationID.isEmpty else { throw TincallError(message: String(localized: "请填写讯飞 App ID")) }
            client = XunfeiSpeechRecognizer(credentials: XunfeiCredentials(xunfeiAppID: applicationID,
                xunfeiAPIKey: try secret(stt.id), xunfeiAPISecret: try secret(stt.id, field: .apiSecret)), logContext: logContext,
                connectionName: stt.name)
        case .appleSpeech:
            let language = stt.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            client = AppleSpeechRecognizer(language: language.isEmpty ? "zh-CN" : language,
                                           logContext: logContext, connectionName: stt.name)
        case .bailian:
            guard stt.region == nil || stt.region == "beijing" else {
                throw TincallError(message: String(localized: "百炼 Paraformer 实时识别当前仅支持北京地区"))
            }
            let model = stt.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model.isEmpty || model == "paraformer-realtime-v2" else {
                throw TincallError(message: String(localized: "百炼识别请使用 paraformer-realtime-v2 模型"))
            }
            client = BailianSpeechRecognizer(configuration: BailianConfiguration(apiKey: try secret(stt.id),
                model: model.isEmpty ? "paraformer-realtime-v2" : model), logContext: logContext, connectionName: stt.name)
        case .whisperCompatible:
            client = WhisperSpeechRecognizer(configuration: try WhisperConfiguration(endpoint: stt.endpoint,
                model: stt.model, language: stt.language, apiKey: credentials.read(connectionID: stt.id)), logContext: logContext,
                connectionName: stt.name)
        default: throw TincallError(message: String(localized: "请选择受支持的语音识别连接"))
        }
        return client
    }

    private func startRecognition(client candidate: (any SpeechRecognizer)? = nil) async throws {
        guard let session, let configuration else { throw CancellationError() }
        CallAudioDiagnostics.record(.recognizerStart, turn: turn?.turnID, input: inputID)
        let client = try candidate ?? makeRecognizer(configuration.stt, session: session)
        recognizer = client
        client.onSpeechActivityChange = { [weak self, weak client] active in
            guard let self, let client, self.session == session, self.recognizer === client else { return }
            let speaking = active && !self.microphoneMuted && !self.textInputActive &&
                !self.audioInterrupted && !self.transcriptionPaused
            self.updateUserSpeechDucking(speaking)
            self.onEvent?(.speechActivity(session, speaking))
        }
        do {
            try await client.start(callback: { [weak self, weak client] text, final, pcm in
                guard let self, self.session == session, self.recognizer === client else { return }
                self.updateRecognitionPolicy()
                guard !self.transcriptionPaused, !self.microphoneMuted, !self.audioInterrupted else {
                    CallAudioDiagnostics.record(.transcriptDroppedPaused, turn: self.turn?.turnID, input: self.inputID, count: text.count, flag: final)
                    return
                }
                // A delayed STT callback cannot bypass the processed-audio gate.
                guard !MicrophoneCapture.requiresSustainedSpeech || MicrophoneCapture.speechInterruptionReady else {
                    CallAudioDiagnostics.record(.transcriptDroppedGate, turn: self.turn?.turnID, input: self.inputID, count: text.count, flag: final)
                    return
                }
                let id = self.inputID
                guard self.finalInputID != id else {
                    CallAudioDiagnostics.record(.transcriptDroppedFinal, turn: self.turn?.turnID, input: id, count: text.count, flag: final)
                    return
                }
                CallAudioDiagnostics.record(.transcriptForwarded, turn: self.turn?.turnID, input: id, count: text.count, flag: final)
                self.hasPartialTranscript = !final && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if final { self.finalInputID = id }
                let inputAudio = final && self.configuration?.stt.provider == .appleSpeech
                    ? pcm.map { SpeechPlayback.waveData(pcm: $0, sampleRate: 16_000) } : nil
                self.onEvent?(.transcript(session, TranscriptResult(inputID: id, text: text, isFinal: final, audio: inputAudio)))
                if final, self.session == session, self.configuration?.retention.user == true, let pcm, !pcm.isEmpty {
                    self.deliverAudio(SpeechPlayback.waveData(pcm: pcm, sampleRate: 16_000),
                                      messageID: id, segmentIndex: 0, sampleRate: 16_000)
                }
            }, onError: { [weak self, weak client] error in
                guard let self, self.session == session, self.recognizer === client else { return }
                MicrophoneCapture.recordDiagnostic(.microphoneFailed, phase: "recognizer_async",
                    turn: self.turn?.turnID, input: self.inputID, error: error)
                client?.stop()
                self.microphoneMuted = true
                self.recognizer = nil
                self.clearCaption()
                self.updateRecognitionPolicy()
                self.onEvent?(.microphoneState(session, true))
                self.onEvent?(.failure(session, Self.safeError(error).message))
            }, onReset: { [weak self, weak client] in
                guard let self, self.session == session, self.recognizer === client else { return }
                self.inputID = UUID()
                CallAudioDiagnostics.record(.recognizerReset, turn: self.turn?.turnID, input: self.inputID)
                self.finalInputID = nil
                self.clearCaption()
            })
            guard self.session == session, recognizer === client else { client.stop(); throw CancellationError() }
            updateRecognitionPolicy()
        } catch {
            if recognizer === client { recognizer = nil }
            await client.stopAndWait()
            throw error
        }
    }

    private func clearCaption() {
        hasPartialTranscript = false
        if let session { onEvent?(.transcript(session, TranscriptResult(inputID: inputID, text: "", isFinal: false))) }
    }

    private func stopReply() {
        if let turn { CallAudioDiagnostics.record(.replyStop, turn: turn.turnID, input: inputID) }
        playbackTask?.cancel(); playbackTask = nil
        playback.stop()
        replyPlaybackStarted = false
        turn = nil
        updateOtherAudioDucking()
        updateRecognitionPolicy()
    }

    private var shouldDuckOtherAudio: Bool {
        // A streamed reply may briefly exhaust its PCM queue. Reconfiguring
        // the session at every packet gap can interrupt the output itself.
        ((playback.isActive && replyPlaybackStarted) || userSpeechDuckingActive) && !audioInterrupted
    }

    private func updateUserSpeechDucking(_ speaking: Bool) {
        guard let identity = session else { return }
        if speaking {
            speechDuckingReleaseTask?.cancel()
            speechDuckingReleaseTask = nil
            guard !userSpeechDuckingActive else { return }
            userSpeechDuckingActive = true
            updateOtherAudioDucking()
        } else {
            guard userSpeechDuckingActive, speechDuckingReleaseTask == nil else { return }
            speechDuckingReleaseTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                guard let self, self.session == identity, !Task.isCancelled else { return }
                self.speechDuckingReleaseTask = nil
                self.userSpeechDuckingActive = false
                self.updateOtherAudioDucking()
            }
        }
    }

    private func clearUserSpeechDucking() {
        speechDuckingReleaseTask?.cancel()
        speechDuckingReleaseTask = nil
        guard userSpeechDuckingActive else { return }
        userSpeechDuckingActive = false
        updateOtherAudioDucking()
    }

    private func updateOtherAudioDucking() {
        guard let identity = session else { return }
        guard !audioInterrupted else { requestedDucking = nil; return }
        let enabled = shouldDuckOtherAudio
        guard requestedDucking != enabled else { return }
        requestedDucking = enabled
        duckingRevision += 1
        let revision = duckingRevision
        Task { [weak self] in
            guard let self, self.session == identity, self.duckingRevision == revision, !self.audioInterrupted else { return }
            self.beginOutputChange()
            defer { self.endOutputChange(session: identity) }
            do {
                try await self.audioRouting.setDucking(enabled, revision: revision, session: identity)
                guard self.session == identity else { return }
                let audio = AVAudioSession.sharedInstance()
                CallAudioDiagnostics.record(.otherAudioDucking, count: revision, flag: enabled,
                    phase: "after_request", category: audio.category.rawValue, mode: audio.mode.rawValue,
                    options: audio.categoryOptions.rawValue)
            }
            catch {
                guard self.session == identity else { return }
                self.logger.error("phase=call_other_audio_ducking_failed error_code=\((error as NSError).code)")
                MicrophoneCapture.recordDiagnostic(.audioRoutingFailed,
                    phase: enabled ? "duck_enable" : "duck_disable", error: error)
                guard self.duckingRevision == revision, !self.audioInterrupted else { return }
                self.requestedDucking = nil
                self.onEvent?(.failure(identity, String(localized: "无法调整其他 App 的音量，请重试通话")))
            }
        }
    }

    private func refreshBluetooth(preferAutomatic: Bool, session identity: VoiceSessionID) {
        if preferAutomatic { pendingAutomaticOutput = true }
        guard bluetoothRefreshTask == nil else { return }
        bluetoothRefreshTask = Task { [weak self] in
            guard let self, self.session == identity, !Task.isCancelled else { return }
            self.beginOutputChange()
            let automatic = self.pendingAutomaticOutput
            self.pendingAutomaticOutput = false
            defer {
                if self.session == identity {
                    self.bluetoothRefreshTask = nil
                    if self.pendingAutomaticOutput { self.refreshBluetooth(preferAutomatic: true, session: identity) }
                }
                self.endOutputChange(session: identity)
            }
            do {
                guard !self.audioInterrupted else { return }
                let available = try await self.audioRouting.refreshBluetooth(preferAutomatic: automatic, session: identity)
                guard self.session == identity, !Task.isCancelled else { return }
                self.bluetoothRepairFailed = !available
                if automatic { self.speakerOverride = nil }
                if !available {
                    self.onEvent?(.failure(identity, String(localized: "无法启用蓝牙音频输出，请重新连接耳机")))
                }
                self.reportSpeakerState()
            } catch is CancellationError { }
            catch {
                guard self.session == identity else { return }
                self.bluetoothRepairFailed = true
                MicrophoneCapture.recordDiagnostic(.audioRoutingFailed, phase: "route_repair", error: error)
                self.onEvent?(.failure(identity, Self.safeError(error).message))
            }
        }
    }

    private func updateRecognitionPolicy() {
        guard let session else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let headphones = !outputs.isEmpty && outputs.allSatisfy { $0.portType == .headphones }
        let availability: SpeechInterruptionAvailability
        if microphoneMuted || textInputActive { availability = .microphoneMuted }
        else if audioInterrupted || recognizer == nil { availability = .recognitionUnavailable }
        else if outputs.isEmpty { availability = .unavailable }
        else { availability = headphones ? .headphones : .beforePlaybackOnly }

        // Processed microphone input stays available on every route when enabled,
        // including gaps between reply segments. Disabled retains the old pause.
        transcriptionPaused = preparingIncomingAudio || microphoneMuted || textInputActive || audioInterrupted || (playback.isActive && !speechInterruptionEnabled)
        if transcriptionPaused || recognizer == nil { clearUserSpeechDucking() }
        MicrophoneCapture.requiresSustainedSpeech = playback.isActive && speechInterruptionEnabled &&
            !transcriptionPaused && !microphoneMuted
        recognizer?.setTranscriptionPaused(transcriptionPaused)
        if interruptionAvailability != availability {
            interruptionAvailability = availability
            onEvent?(.speechInterruptionAvailability(session, availability))
        }
    }

    private func observeRouteChanges(session: VoiceSessionID) {
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                                object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                let preference = self.speakerOverride.map { $0 ? "speaker" : "receiver" } ?? "automatic"
                MicrophoneCapture.recordDiagnostic(.audioRouteChanged,
                    phase: "reason_\(reason)_preference_\(preference)", turn: self.turn?.turnID, input: self.inputID)
                let audio = AVAudioSession.sharedInstance()
                let external = audio.currentRoute.outputs.contains {
                    $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
                }
                let newDevice = reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                if newDevice { self.bluetoothRepairFailed = false }
                if audio.categoryOptions.contains(.allowBluetoothA2DP) { self.bluetoothRepairFailed = false }
                let preferAutomatic = newDevice || (external && self.outputChangesInFlight == 0 && self.speakerOverride != nil)
                let needsAudioRepair = !audio.categoryOptions.contains([.allowBluetoothA2DP, .mixWithOthers]) ||
                    audio.categoryOptions.contains(.duckOthers) != self.shouldDuckOtherAudio
                if !self.audioInterrupted && (preferAutomatic || (needsAudioRepair && !self.bluetoothRepairFailed)) {
                    self.refreshBluetooth(preferAutomatic: preferAutomatic, session: session)
                }
                self.updateRecognitionPolicy()
                self.reportSpeakerState()
            }
        }
    }

    private func deliverAudio(_ data: Data, messageID: UUID, segmentIndex: Int, sampleRate: Double) {
        guard let session else { return }
        var file: URL?
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TincallVoice", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID()
            let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("wav")
            file = url
            try data.write(to: url, options: .atomic)
            guard let onEvent else {
                try FileManager.default.removeItem(at: url)
                throw TincallError(message: String(localized: "音频记录尚未连接存储"))
            }
            let duration = Double(max(0, data.count - 44)) / (sampleRate * 2)
            onEvent(.audioReady(session, VoiceAudioSegment(id: id, messageID: messageID,
                                                         segmentIndex: segmentIndex, fileURL: url, duration: duration)))
        } catch {
            if let file { try? FileManager.default.removeItem(at: file) }
            onEvent?(.failure(session, String(localized: "音频交付失败，请检查本地存储")))
        }
    }

    private func startIndependentAudio() async throws {
        guard let identity = session else { throw CancellationError() }
        guard backgroundEngine?.isRunning != true || backgroundPlayer?.isPlaying != true else { return }
        let audio = AVAudioSession.sharedInstance()
        if let engine = backgroundEngine, let player = backgroundPlayer, let silence = backgroundBuffer {
            // Restart only this graph. Resetting VoiceChat to default here
            // would stop the microphone graph and change the volume controls.
            MicrophoneCapture.recordDiagnostic(.independentAudioStage, phase: "restore_activate")
            try await audioRouting.activate(session: identity)
            guard session == identity else { throw CancellationError() }
            player.stop()
            logSession("call_background_restart", session: audio)
            MicrophoneCapture.recordDiagnostic(.independentAudioStage, phase: "restore_engine_start")
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
            player.play()
            reportSpeakerState()
            return
        }
        logSession("call_session_configure", session: audio)
        MicrophoneCapture.recordDiagnostic(.independentAudioStage, phase: "prepare_session")
        try await audioRouting.prepare(session: identity)
        guard session == identity else { throw CancellationError() }
        logSession("call_session_activate", session: audio)
        reportSpeakerState()
        logSession("call_session_active", session: audio)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000),
              let samples = silence.floatChannelData?[0] else { throw TincallError(message: String(localized: "无法准备独立通话音频")) }
        silence.frameLength = 24_000
        samples.initialize(repeating: 0, count: 24_000)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        logSession("call_background_start", session: audio)
        MicrophoneCapture.recordDiagnostic(.independentAudioStage, phase: "initial_engine_start")
        try engine.start()
        player.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
        player.play()
        backgroundEngine = engine; backgroundPlayer = player; backgroundBuffer = silence
        let expectedSession = session
        let observationID = UUID()
        backgroundObservationID = observationID
        backgroundConfigurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.backgroundObservationID == observationID, let engine = self.backgroundEngine, let expectedSession,
                      self.session == expectedSession, !self.audioInterrupted, !engine.isRunning else { return }
                guard self.outputChangesInFlight == 0 else { return }
                do { try await self.startIndependentAudio() }
                catch {
                    MicrophoneCapture.recordDiagnostic(.independentAudioFailed, phase: "engine_configuration", error: error)
                    self.onEvent?(.failure(expectedSession, Self.safeError(error).message))
                }
            }
        }
    }

    private func logSession(_ phase: String, session: AVAudioSession) {
        logger.info("phase=\(phase, privacy: .public) category=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) options=\(session.categoryOptions.rawValue)")
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                       object: nil, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            Task { @MainActor [weak self] in
                guard let self, self.session != nil, let rawType else { return }
                CallAudioDiagnostics.record(.audioInterruption, flag: rawType == AVAudioSession.InterruptionType.began.rawValue,
                                            phase: shouldResume ? "resume" : "no_resume")
                if rawType == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioInterrupted = true
                    self.recognizer?.stop(); self.recognizer = nil
                    self.clearCaption()
                    self.updateRecognitionPolicy()
                    self.playback.setAudioInterrupted(true)
                    self.updateOtherAudioDucking()
                    self.backgroundEngine?.pause()
                    if let identity = self.session {
                        self.onEvent?(.microphoneState(identity, true))
                        self.duckingRevision += 1
                        await self.audioRouting.suspendDucking(revision: self.duckingRevision, session: identity)
                    }
                } else {
                    // Manual recovery may finish before this delayed notification.
                    guard self.audioInterrupted else { return }
                    self.audioInterrupted = false
                    guard shouldResume else {
                        self.microphoneMuted = true
                        self.updateRecognitionPolicy()
                        if let session { self.onEvent?(.microphoneState(session, true)) }
                        return
                    }
                    let expectedSession = self.session
                    do {
                        try await self.startIndependentAudio()
                        self.playback.setAudioInterrupted(false)
                        self.updateOtherAudioDucking()
                        if !self.microphoneMuted, self.recognitionSwitchID == nil { try await self.startRecognition() }
                        if self.session == expectedSession, let identity = self.session {
                            self.onEvent?(.microphoneState(identity, self.microphoneMuted))
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard self.session == expectedSession else { return }
                        self.recognizer?.stop(); self.recognizer = nil
                        self.microphoneMuted = true
                        self.updateRecognitionPolicy()
                        if let session = self.session {
                            self.onEvent?(.microphoneState(session, true))
                            self.onEvent?(.failure(session, Self.safeError(error).message))
                        }
                    }
                }
            }
        }
    }

    private static func safeError(_ error: Error) -> TincallError {
        if let error = error as? TincallError { return error }
        if let error = error as? URLError { return TincallError(message: String(localized: "语音连接失败（\(error.code.rawValue)）")) }
        return TincallError(message: String(localized: "语音处理失败，请检查连接和音频权限"))
    }

    private static func microphoneStartError(_ error: Error) -> TincallError {
        if let error = error as? TincallError { return error }
        let code = String((error as NSError).code)
        return TincallError(message: String(localized: "麦克风启动失败（错误码：\(code)）"))
    }
}
