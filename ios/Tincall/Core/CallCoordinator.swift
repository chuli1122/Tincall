// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation
import Observation

@MainActor
@Observable
final class CallCoordinator {
    var phase: CallPhase = .idle
    private(set) var endedByRemote = false
    var generation: GenerationState = .idle
    var playback: PlaybackState = .idle
    var partialTranscript = ""
    var floatingUserTranscript = ""
    var isUserSpeaking = false
    var isAwaitingSpeechTranscript = false
    var isMuted = false
    var isSpeakerEnabled = false
    var isTextInputActive = false
    var errorMessage: String?
    var revision = 0
    var record: CallRecord?
    var hasUnsavedAudio = false
    var savingCallIDs: Set<UUID> = []
    var externalConnectionLost = false
    var currentPlaybackCaption: String?
    var speechInterruptionEnabled = true
    var speechRecognitionConnectionID: UUID?
    var pendingSpeechRecognitionConnection: ConnectionProfile?
    var isSwitchingSpeechRecognition = false
    var speechRecognitionError: String?
    var originalAudioInputEnabled = false
    var pendingOriginalAudioInputEnabled: Bool?
    @ObservationIgnored var textRecognitionConnection: ConnectionProfile?
    @ObservationIgnored var pendingInputAudio: [UUID: Data] = [:]
    @ObservationIgnored var speechRecognitionTask: Task<Void, Never>?
    var speechInterruptionAvailability: SpeechInterruptionAvailability = .unavailable

    @ObservationIgnored var onSaveRecord: ((CallRecord) throws -> Void)?
    @ObservationIgnored var onSaveAudio: ((UUID, VoiceAudioSegment) throws -> CallAudioAsset)?
    @ObservationIgnored var onSaveImages: ((UUID, UUID, [Data]) throws -> [CallImageAsset])?
    @ObservationIgnored var onLoadImages: ((UUID, CallMessage) throws -> [Data])?
    @ObservationIgnored var onDiscardImages: ((UUID, UUID, [CallImageAsset]) throws -> Void)?
    /// Persists a successfully selected in-call STT connection as the next-call default.
    @ObservationIgnored var onSpeechRecognitionUsed: ((UUID) throws -> Void)?
    @ObservationIgnored var onStartOutgoingAudio: (@MainActor (VoiceSessionID, CallRole, VoiceConfiguration) async throws -> Void)?
    @ObservationIgnored let model: ChatCompletionClient
    @ObservationIgnored let external: ExternalCallClient
    @ObservationIgnored let voice: any VoiceService
    @ObservationIgnored let summaryUserName: () -> String
    @ObservationIgnored let transcriptCorrections: () -> [SpeechRecognitionCorrection]
    @ObservationIgnored var session: VoiceSessionID?
    @ObservationIgnored var sessions: [UUID: VoiceSessionID] = [:]
    @ObservationIgnored var records: [UUID: CallRecord] = [:]
    @ObservationIgnored var turns: [UUID: VoiceTurnID] = [:]
    @ObservationIgnored var modelEndTurn: VoiceTurnID?
    @ObservationIgnored var externalEndSession: VoiceSessionID?
    @ObservationIgnored var externalReplyQueue: [(turn: VoiceTurnID, replyID: UUID, inputID: UUID?)] = []
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let summaryTasks: CallSummaryTasks
    @ObservationIgnored var pendingAudio: [UUID: [VoiceAudioSegment]] = [:]
    @ObservationIgnored var finalInputs: Set<UUID> = []
    @ObservationIgnored var pendingFinalInputs: [UUID: [CallMessage]] = [:]
    @ObservationIgnored var interruptedSpeechInputs: Set<UUID> = []
    @ObservationIgnored var partialInput: TranscriptResult?
    @ObservationIgnored var role: CallRole?
    @ObservationIgnored var connection: ConnectionProfile?
    @ObservationIgnored var ttsConnection: ConnectionProfile?
    @ObservationIgnored var historyRecords: [CallRecord] = []
    @ObservationIgnored var externalConnections: [UUID: ConnectionProfile] = [:]
    @ObservationIgnored var externalEventsTask: Task<Void, Never>?
    @ObservationIgnored var externalEventsError: String?
    @ObservationIgnored var externalControlTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var externalInputIDs: [UUID: UUID] = [:]
    @ObservationIgnored var externalReplyIDs: [UUID: UUID] = [:]
    @ObservationIgnored var externalTimestampFilter: (turn: VoiceTurnID, filter: CallTimestampStreamFilter)?
    @ObservationIgnored var audioSegmentOffsets: [UUID: Int] = [:]
    @ObservationIgnored var preparedIncoming: (session: VoiceSessionID, configuration: VoiceConfiguration, accepted: Bool)?
    struct IncomingOpening {
        let roleID: UUID
        let turn: VoiceTurnID
        var text = ""
        var status: MessageStatus = .generating
        var error: Error?
        var requestsEnd = false
        var attached = false
    }
    @ObservationIgnored var incomingOpening: IncomingOpening?
    @ObservationIgnored var textOnly = false
    @ObservationIgnored var muteTransitionID: UUID?
    @ObservationIgnored var speakerTransitionID: UUID?
    @ObservationIgnored var speakerStateDuringTransition: Bool?
    @ObservationIgnored private var activityCheckpointTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointSession: VoiceSessionID?
    @ObservationIgnored private var checkpointStartedAt: Date?
    @ObservationIgnored private var checkpointBaseDuration: TimeInterval = 0

    init(voice: any VoiceService, model: ChatCompletionClient = ChatCompletionClient(), external: ExternalCallClient = ExternalCallClient(),
         transcriptCorrections: @escaping () -> [SpeechRecognitionCorrection] = { [] },
         summaryUserName: @escaping () -> String = { "" }) {
        self.voice = voice
        self.model = model
        self.summaryTasks = CallSummaryTasks(model: model)
        self.external = external
        self.transcriptCorrections = transcriptCorrections
        self.summaryUserName = summaryUserName
        voice.onEvent = { [weak self] event in self?.receive(event) }
    }

    var isCallActive: Bool { phase == .active || phase == .connecting }
    var connectedAt: Date? {
        guard phase != .connecting, let record, record.lastActiveAt != nil else { return nil }
        return record.startedAt
    }
    var canSend: Bool { phase == .active && session != nil && externalEndSession == nil }
    var canInterrupt: Bool { generation == .generating || (isCallActive && (playback == .playing || playback == .synthesizing)) }
    var pendingInputCount: Int { record?.queuedInputIDs?.count ?? 0 }
    var supportsOriginalAudioInput: Bool {
        role?.effectiveCallMode == .standalone && (connection?.provider == .gemini || connection?.provider == .openAICompatible)
    }

    func start(role: CallRole, connections: [ConnectionProfile], retention: AudioRetention, historyRecords: [CallRecord] = [], textOnly: Bool = false) async {
        guard !isCallActive, !Task.isCancelled else { return }
        // The destination is visible while access and connection checks run.
        record = nil
        do { try await CallAccessStore.shared.requireAccess() }
        catch {
            errorMessage = safeMessage(error)
            CallAccessStore.shared.showsUnlock = true
            return
        }
        guard !isCallActive, !Task.isCancelled else { return }
        if let opening = incomingOpening { cancelIncomingOpening(callID: opening.turn.session.callID) }
        errorMessage = nil
        if !textOnly, let saved = (Array(records.values) + historyRecords)
            .filter({ canResumeExternal($0, role: role) })
            .max(by: { $0.startedAt < $1.startedAt }) {
            await resumeExternal(record: saved, role: role, connections: connections, retention: retention)
            // A remotely ended call is finalized above; only then may this dial start a new one.
            guard phase == .ended else { return }
        }
        do {
            let connection: ConnectionProfile
            let stt: ConnectionProfile?
            let tts: ConnectionProfile?
            if textOnly {
                connection = try validatedSource(role: role, connections: connections)
                stt = nil
                tts = nil
            } else {
                (connection, stt, tts) = try validatedConnections(role: role, connections: connections)
            }
            self.textOnly = textOnly
            let newRecord = CallRecord(roleID: role.id, roleName: role.displayName, callMode: role.effectiveCallMode,
                                       externalConnectionID: role.externalConnectionID,
                                       externalRoleID: role.effectiveCallMode == .standalone ? nil : role.externalRoleID)
            try save(newRecord)
            self.role = role
            self.connection = connection
            self.ttsConnection = tts
            resetSpeechRecognitionSelection(stt?.id)
            self.historyRecords = historyRecords.filter { $0.id != newRecord.id }
            record = newRecord
            records[newRecord.id] = newRecord
            if !textOnly, let summaryID = role.summaryConnectionID {
                summaryTasks.configure(callID: newRecord.id, role: role, connection: connections.first { $0.id == summaryID })
            }
            let newSession = VoiceSessionID(callID: newRecord.id, epoch: UUID())
            session = newSession
            sessions[newRecord.id] = newSession
            finalInputs.removeAll()
            interruptedSpeechInputs.removeAll()
            partialTranscript = ""
            floatingUserTranscript = ""
            isUserSpeaking = false
            isAwaitingSpeechTranscript = false
            partialInput = nil
            generation = .idle
            playback = .idle
            currentPlaybackCaption = nil
            speechInterruptionAvailability = .unavailable
            isMuted = false
            muteTransitionID = nil
            isSpeakerEnabled = false
            speakerTransitionID = nil
            phase = .connecting
            do {
                if role.effectiveCallMode != .standalone {
                    externalConnections[newRecord.id] = connection
                    mutate(newRecord.id) { $0.externalCallID = newRecord.id; $0.externalEpoch = 0; $0.externalEventCursor = 0 }
                    try save(records[newRecord.id] ?? newRecord)
                    let state = try await external.create(connection: connection, role: role, callID: newRecord.id,
                                                          expressionPrompt: tts?.effectiveExpressionPrompt ?? "", userName: summaryUserName())
                    mutate(newRecord.id) { $0.externalEpoch = state.epoch }
                    guard session == newSession, phase == .connecting else {
                        enqueueExternalControl(callID: newRecord.id, endsCall: true)
                        return
                    }
                    guard state.status == "active" else { throw TincallError(message: String(localized: "连接端未建立可用通话")) }
                    mutate(newRecord.id) { $0.externalCallID = state.id; $0.externalEpoch = state.epoch; $0.externalEventCursor = 0 }
                    try save(records[newRecord.id] ?? newRecord)
                }
                if let stt, let tts {
                    voice.setSpeechInterruptionEnabled(speechInterruptionEnabled)
                    let audio = VoiceConfiguration(stt: stt, tts: tts, voiceID: resolvedVoiceID(role: role, tts: tts), retention: retention)
                    if let onStartOutgoingAudio { try await onStartOutgoingAudio(newSession, role, audio) }
                    else { try await voice.start(session: newSession, configuration: audio) }
                }
                guard session == newSession, phase == .connecting else { return }
                mutate(newRecord.id) { $0.startedAt = Date() }
                phase = .active
                startActivityCheckpoints(newSession)
                externalConnectionLost = false
                if role.effectiveCallMode != .standalone { startExternalEvents(session: newSession, connection: connection) }
            } catch {
                guard session == newSession else { return }
                stopActivityCheckpoints(newSession)
                if !textOnly { voice.stop() }
                phase = .failed
                isUserSpeaking = false
                isAwaitingSpeechTranscript = false
                session = nil
                mutate(newRecord.id) { $0.endedAt = Date(); $0.endedAbnormally = true }
                persist(newRecord.id)
                if role.effectiveCallMode != .standalone { enqueueExternalControl(callID: newRecord.id, endsCall: true) }
                throw error
            }
        } catch { errorMessage = safeMessage(error); if !isCallActive { phase = .failed } }
    }

    func hangUp(abnormally: Bool = false, remotely: Bool = false) {
        guard isCallActive, let session else { return }
        incomingOpening = nil
        preparedIncoming = nil
        endedByRemote = remotely
        externalEndSession = nil
        modelEndTurn = nil
        stopActivityCheckpoints(session)
        RequestLogStore.shared.markHangUp(callID: session.callID)
        discardQueuedExternalReplies(reason: .hangUp)
        if canInterrupt, let turn = turns[session.callID] {
            cancelReply(turn, reason: .hangUp)
        } else {
            turns.removeValue(forKey: session.callID)
            tasks.removeValue(forKey: session.callID)?.cancel()
        }
        if let input = partialInput, !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !finalInputs.contains(input.inputID),
           pendingFinalInputs[session.callID]?.contains(where: { $0.id == input.inputID }) != true {
            let user = CallMessage(id: input.inputID, turnID: UUID(), role: .user,
                                   text: input.text, status: .interrupted, interruption: .hangUp)
            if !accept(user, callID: session.callID) {
                pendingFinalInputs[session.callID, default: []].append(user)
            }
        }
        self.session = nil
        resetSpeechRecognitionSelection()
        isTextInputActive = false
        externalEventsTask?.cancel()
        externalEventsTask = nil
        phase = .ended
        partialTranscript = ""
        floatingUserTranscript = ""
        isUserSpeaking = false
        isAwaitingSpeechTranscript = false
        partialInput = nil
        interruptedSpeechInputs.removeAll()
        if !textOnly { voice.stop() }
        playback = .idle
        currentPlaybackCaption = nil
        speechInterruptionAvailability = .unavailable
        mutate(session.callID) { $0.endedAt = Date(); $0.endedAbnormally = abnormally ? true : nil; $0.queuedInputIDs = nil }
        persist(session.callID)
        enqueueExternalControl(callID: session.callID, endsCall: true)
        // Summary is a separate task; the interrupted reply cannot continue.
        if summaryTasks.isConfigured(session.callID) {
            if pendingFinalInputs[session.callID]?.isEmpty == false {
                mutate(session.callID) { $0.summaryStatus = .pending }
                persist(session.callID)
            } else { requestSummary(callID: session.callID) }
        }
    }

    private enum Unsent {
        static let signal = "78455 4373"
        static let echo = "fgnl n yvggyr ybatre"

        static func forgetYou(when: Never) -> Never {
            switch when {}
        }
    }

    func retrySaving() {
        for id in Array(records.keys) {
            persist(id)
            while let user = pendingFinalInputs[id]?.first {
                guard accept(user, callID: id, queued: session?.callID == id && phase == .active) else { break }
                pendingFinalInputs[id]?.removeFirst()
                if pendingFinalInputs[id]?.isEmpty != false, pendingAudio[id]?.isEmpty != false { savingCallIDs.remove(id) }
                if session?.callID == id, phase == .active {
                    finalInputs.insert(user.id)
                    partialTranscript = ""
                }
            }
            persistAudio(id)
            if session?.callID == id, records[id]?.externalPendingInput != nil { sendExternalInput(callID: id) }
            if records[id]?.externalPendingControl != nil { sendExternalControl(callID: id) }
            if pendingFinalInputs[id]?.isEmpty != false, records[id]?.endedAt != nil,
               records[id]?.summaryStatus == .pending, summaryTasks.isConfigured(id) {
                requestSummary(callID: id)
            }
        }
        beginQueuedInput()
    }

    func withActivityCheckpoint(_ value: CallRecord) -> CallRecord {
        guard let checkpointSession, checkpointSession == session,
              checkpointSession.callID == value.id, isCallActive,
              let checkpointStartedAt else { return value }
        var updated = value
        let now = Date()
        updated.lastActiveAt = max(now, value.startedAt)
        updated.recordedActiveDuration = checkpointBaseDuration + max(0, now.timeIntervalSince(checkpointStartedAt))
        return updated
    }

    func startActivityCheckpoints(_ identity: VoiceSessionID) {
        activityCheckpointTask?.cancel()
        checkpointSession = identity
        checkpointBaseDuration = records[identity.callID]?.recordedDuration ?? 0
        checkpointStartedAt = Date()
        checkpointActivity(identity)
        activityCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard let self, self.session == identity, self.isCallActive else { return }
                self.checkpointActivity(identity)
            }
        }
    }

    private func checkpointActivity(_ identity: VoiceSessionID) {
        guard checkpointSession == identity, session == identity, isCallActive,
              let value = records[identity.callID] else { return }
        records[identity.callID] = withActivityCheckpoint(value)
        publish(identity.callID)
        persist(identity.callID)
    }

    func stopActivityCheckpoints(_ identity: VoiceSessionID) {
        guard checkpointSession == identity else { return }
        checkpointActivity(identity)
        activityCheckpointTask?.cancel()
        activityCheckpointTask = nil
        checkpointSession = nil
        checkpointStartedAt = nil
    }

    func safeMessage(_ error: Error) -> String {
        if let error = error as? TincallError { return error.message }
        if let error = error as? ExternalCallFailure { return error.localizedDescription }
        return String(localized: "操作失败（\((error as NSError).code)）")
    }
}
