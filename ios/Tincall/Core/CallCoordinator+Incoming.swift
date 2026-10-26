// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

extension CallCoordinator {
    func prepareIncomingOpening(callID: UUID, role: CallRole, connections: [ConnectionProfile],
                                retention: AudioRetention = AudioRetention(), historyRecords: [CallRecord] = []) throws {
        guard role.effectiveCallMode == .standalone else { return }
        guard incomingOpening?.turn.session.callID != callID else { return }
        guard !isCallActive else { throw CancellationError() }
        try CallAccessStore.shared.requireCurrentAccess()
        if let opening = incomingOpening { cancelIncomingOpening(callID: opening.turn.session.callID) }
        let (connection, stt, tts) = try validatedConnections(role: role, connections: connections)
        let context = try CallContextBuilder.build(role: role, historyRecords: historyRecords.filter { $0.id != callID },
            currentMessages: [], ttsConnection: tts, userName: summaryUserName(), assistantInitiated: true)
        let turn = VoiceTurnID(session: VoiceSessionID(callID: callID, epoch: UUID()), turnID: UUID(), messageID: UUID())
        RequestLogStore.shared.registerCall(id: callID, startedAt: Date(), mode: role.effectiveCallMode)
        RequestLogStore.shared.registerTurn(callID: callID, inputID: turn.turnID, turnID: turn.turnID)
        try voice.prepareIncomingReply(turn, configuration: VoiceConfiguration(stt: stt, tts: tts,
            voiceID: resolvedVoiceID(role: role, tts: tts), retention: retention))
        incomingOpening = IncomingOpening(roleID: role.id, turn: turn)
        tasks[callID] = Task { [weak self, model] in
            do {
                var timestampFilter = CallTimestampStreamFilter()
                var endFilter = CallEndStreamFilter()
                let timeAware = role.timeAwarenessEnabled == true
                _ = try await model.stream(connection: connection, messages: context.messages,
                    logContext: RequestLogStore.shared.context(for: turn), omittedTurnCount: context.omittedTurnCount) { delta in
                    let cleaned = endFilter.append(delta)
                    let text = timeAware ? timestampFilter.append(cleaned) : cleaned
                    if !text.isEmpty { self?.receiveOpeningDelta(text, turn: turn) }
                }
                let endTail = endFilter.append("", final: true)
                let tail = timeAware ? timestampFilter.append(endTail, final: true) : endTail
                if !tail.isEmpty { self?.receiveOpeningDelta(tail, turn: turn) }
                self?.finishIncomingOpening(turn, error: nil, requestsEnd: endFilter.requestsEnd)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishIncomingOpening(turn, error: error)
            }
        }
    }

    func cancelIncomingOpening(callID: UUID) {
        guard let opening = incomingOpening, opening.turn.session.callID == callID, !opening.attached else { return }
        incomingOpening = nil
        tasks.removeValue(forKey: callID)?.cancel()
        voice.interruptReply(opening.turn)
    }

    private func receiveOpeningDelta(_ text: String, turn: VoiceTurnID) {
        guard incomingOpening?.turn == turn else { return }
        if incomingOpening?.attached == true { receiveDelta(text, turn: turn); return }
        incomingOpening?.text += text
        do { try voice.appendReply(text, to: turn) }
        catch { finishIncomingOpening(turn, error: error); tasks.removeValue(forKey: turn.session.callID)?.cancel() }
    }

    private func finishIncomingOpening(_ turn: VoiceTurnID, error: Error?, requestsEnd: Bool = false) {
        guard incomingOpening?.turn == turn else { return }
        if incomingOpening?.attached == true {
            incomingOpening = nil
            if requestsEnd { modelEndTurn = turn }
            complete(turn, status: error == nil ? .completed : .failed, error: error)
            return
        }
        incomingOpening?.status = error == nil ? .completed : .failed
        incomingOpening?.error = error
        incomingOpening?.requestsEnd = requestsEnd
        if error == nil {
            do { try voice.finishReply(turn) }
            catch { incomingOpening?.status = .failed; incomingOpening?.error = error; voice.interruptReply(turn) }
        } else { voice.interruptReply(turn) }
    }

    func prepareIncoming(callID: UUID, role: CallRole, connector: ConnectionProfile, connections: [ConnectionProfile],
                         retention: AudioRetention, historyRecords: [CallRecord] = []) async throws {
        try await CallAccessStore.shared.requireAccess()
        guard !isCallActive else { throw TincallError(message: String(localized: "已有通话正在进行")) }
        errorMessage = nil
        let (modelConnection, stt, tts) = try validatedConnections(role: role, connections: connections)
        try external.validate(connector)
        if incomingOpening?.roleID != role.id, let opening = incomingOpening {
            cancelIncomingOpening(callID: opening.turn.session.callID)
        }
        // Also covers answering before the report callback has started preparation.
        try prepareIncomingOpening(callID: callID, role: role, connections: connections,
            retention: retention, historyRecords: historyRecords)
        self.textOnly = false
        var value = records[callID] ?? historyRecords.first(where: { $0.id == callID }) ?? CallRecord(
            id: callID, roleID: role.id, roleName: role.displayName, callMode: role.effectiveCallMode,
            externalConnectionID: connector.id,
            externalRoleID: role.effectiveCallMode == .standalone ? role.id.uuidString : role.externalRoleID,
            externalCallID: callID, externalEventCursor: 0, externalEpoch: 0, externalAnswerRequestID: UUID())
        guard value.externalCallID == callID, value.roleID == role.id, value.endedAt == nil else {
            throw TincallError(message: String(localized: "来电与本地记录不匹配"))
        }
        if value.externalAnswerRequestID == nil { value.externalAnswerRequestID = UUID() }
        value.endedAbnormally = nil
        try save(value)
        record = value
        records[callID] = value
        self.role = role
        self.connection = modelConnection
        self.ttsConnection = tts
        resetSpeechRecognitionSelection(stt.id)
        self.historyRecords = historyRecords.filter { $0.id != callID }
        externalConnections[callID] = connector
        let identity = incomingOpening?.turn.session ?? VoiceSessionID(callID: callID, epoch: UUID())
        session = identity
        sessions[callID] = identity
        phase = .connecting
        generation = .idle
        playback = .idle
        partialTranscript = ""
        floatingUserTranscript = ""
        isUserSpeaking = false
        isAwaitingSpeechTranscript = false
        partialInput = nil
        interruptedSpeechInputs.removeAll()
        currentPlaybackCaption = nil
        speechInterruptionAvailability = .unavailable
        finalInputs.removeAll()
        if let summaryID = role.summaryConnectionID {
            summaryTasks.configure(callID: callID, role: role, connection: connections.first { $0.id == summaryID })
        }
        preparedIncoming = (identity, VoiceConfiguration(stt: stt, tts: tts,
            voiceID: resolvedVoiceID(role: role, tts: tts), retention: retention), false)
    }

    /// Cloud confirmation is separate from local recording preparation. Neither
    /// an acquired microphone nor a dismissed system call means this succeeded.
    func confirmIncoming(callID: UUID) async throws {
        guard let prepared = preparedIncoming, prepared.session.callID == callID,
              session == prepared.session, phase == .connecting,
              let value = records[callID], let requestID = value.externalAnswerRequestID,
              let role, role.id == value.roleID, let connector = externalConnections[callID] else {
            throw CancellationError()
        }
        let identity = prepared.session
        do {
            let state = try await external.answer(connection: connector, callID: callID,
                requestID: requestID, epoch: value.externalEpoch ?? 0,
                expressionPrompt: prepared.configuration.tts.effectiveExpressionPrompt, userName: summaryUserName(),
                timeAwarenessEnabled: role.timeAwarenessEnabled == true)
            guard session == identity, phase == .connecting else { throw CancellationError() }
            let expectedSource = role.effectiveCallMode == .standalone ? "independent" : role.effectiveCallMode.rawValue
            guard state.id == callID, state.contact_id == value.externalRoleID, state.source == expectedSource else {
                throw TincallError(message: String(localized: "来电联系人或对话来源与本地绑定不匹配"))
            }
            mutate(callID) { $0.externalEpoch = state.epoch }
            if let current = records[callID] { try save(current) }
            preparedIncoming?.accepted = true
        } catch {
            if session == identity { hangUp(abnormally: true) }
            throw error
        }
    }

    /// Publish the connected call only after cloud confirmation. The runtime
    /// can prepare recording earlier without releasing a buffered opening reply.
    func activatePreparedIncoming(callID: UUID) async throws {
        guard let prepared = preparedIncoming, prepared.session.callID == callID,
              session == prepared.session, phase == .connecting, prepared.accepted else { throw TincallError(message: String(localized: "来电准备状态已失效")) }
        preparedIncoming = nil
        do {
            voice.setSpeechInterruptionEnabled(speechInterruptionEnabled)
            // Attach the same reply before start releases its buffered audio. Recognition
            // may still be connecting, but must not delay the already synthesized opening.
            mutate(callID) { $0.startedAt = Date() }
            phase = .active
            startActivityCheckpoints(prepared.session)
            if let opening = incomingOpening, opening.turn.session == prepared.session {
                let turn = opening.turn
                mutate(callID) { $0.messages.append(CallMessage(id: turn.messageID, turnID: turn.turnID,
                    role: .assistant, text: opening.text, status: opening.status)) }
                do { if let value = records[callID] { try save(value) } }
                catch { phase = .connecting; throw error }
                turns[callID] = turn
                incomingOpening?.attached = true
                generation = .generating
                playback = .synthesizing
            }
            try await voice.start(session: prepared.session, configuration: prepared.configuration)
            guard session == prepared.session else { return }
            if let opening = incomingOpening, opening.turn.session == prepared.session, opening.status != .generating {
                incomingOpening = nil
                if opening.requestsEnd { modelEndTurn = opening.turn }
                complete(opening.turn, status: opening.status, error: opening.error)
            }
            isMuted = false
            externalConnectionLost = false
            if let connector = externalConnections[callID] { startExternalEvents(session: prepared.session, connection: connector) }
        } catch {
            if session == prepared.session { hangUp(abnormally: true) }
            throw error
        }
    }

    private enum Between {
        static let word = "between"
    }

    func declineIncoming(callID: UUID, role: CallRole?, connector: ConnectionProfile) async {
        cancelIncomingOpening(callID: callID)
        if session?.callID == callID { hangUp(); return }
        if records[callID] == nil {
            let name = role.map { String(localized: "\($0.displayName)（未接来电）") } ?? String(localized: "未接来电")
            let value = CallRecord(id: callID, roleID: role?.id ?? callID, roleName: name, endedAt: Date(),
                callMode: role?.effectiveCallMode, externalConnectionID: connector.id,
                externalRoleID: role.flatMap { $0.effectiveCallMode == .standalone ? $0.id.uuidString : $0.externalRoleID },
                externalCallID: callID, externalEventCursor: 0, externalEpoch: 0)
            records[callID] = value
            do { try save(value) }
            catch { reportSavingFailure(error, callID: callID) }
        }
        externalConnections[callID] = connector
        enqueueExternalControl(callID: callID, endsCall: true)
    }

    func canResumeExternal(_ saved: CallRecord, role: CallRole) -> Bool {
        role.effectiveCallMode != .standalone && saved.endedAt == nil && saved.roleID == role.id &&
            saved.externalCallID == saved.id && saved.externalConnectionID == role.externalConnectionID &&
            saved.externalRoleID == role.externalRoleID && saved.externalPendingControl?.endsCall != true &&
            (saved.callMode == nil || saved.callMode == role.effectiveCallMode)
    }

    /// Resume after app termination or redial: replay only events after the saved cursor, never old audio.
    func resumeExternal(record saved: CallRecord, role: CallRole, connections: [ConnectionProfile], retention: AudioRetention) async {
        guard !isCallActive, !Task.isCancelled else { return }
        do { try await CallAccessStore.shared.requireAccess() }
        catch {
            errorMessage = safeMessage(error)
            CallAccessStore.shared.showsUnlock = true
            return
        }
        guard !isCallActive, !Task.isCancelled else { return }
        guard canResumeExternal(saved, role: role) else {
            errorMessage = String(localized: "此记录无法按当前联系人配置恢复外部通话")
            return
        }
        errorMessage = nil
        externalEventsError = nil
        var restoringIdentity: VoiceSessionID?
        do {
            let (connection, stt, tts) = try validatedConnections(role: role, connections: connections)
            textOnly = false
            self.role = role
            self.connection = connection
            ttsConnection = tts
            resetSpeechRecognitionSelection(stt.id)
            RequestLogStore.shared.registerCall(id: saved.id, startedAt: saved.startedAt, mode: saved.callMode ?? role.effectiveCallMode)
            var restored = saved
            restored.endedAbnormally = nil
            record = restored
            records[saved.id] = restored
            externalConnections[saved.id] = connection
            externalReplyIDs[saved.id] = saved.externalReplyID
            let identity = VoiceSessionID(callID: saved.id, epoch: UUID())
            restoringIdentity = identity
            session = identity
            sessions[saved.id] = identity
            phase = .connecting
            partialTranscript = ""
            floatingUserTranscript = ""
            isUserSpeaking = false
            isAwaitingSpeechTranscript = false
            partialInput = nil
            interruptedSpeechInputs.removeAll()
            currentPlaybackCaption = nil
            speechInterruptionAvailability = .unavailable
            finalInputs = Set(saved.messages.filter { $0.role == .user }.map(\.id))
            generation = .idle
            playback = .idle
            if let reply = saved.messages.last(where: { $0.role == .assistant && $0.status == .generating }),
               saved.messages.contains(where: { $0.role == .user && $0.turnID == reply.turnID }) ||
                (saved.externalEpoch == 0 && saved.externalReplyID == reply.id && !saved.messages.contains(where: { $0.role == .user })) {
                if let user = saved.messages.last(where: { $0.role == .user && $0.turnID == reply.turnID }) {
                    RequestLogStore.shared.registerTurn(callID: saved.id, inputID: user.id, turnID: user.turnID)
                    externalInputIDs[saved.id] = user.id
                } else { externalInputIDs.removeValue(forKey: saved.id) }
                turns[saved.id] = VoiceTurnID(session: identity, turnID: reply.turnID, messageID: reply.id)
                audioSegmentOffsets[reply.id] = (saved.audioAssets.filter { $0.messageID == reply.id }.map(\.segmentIndex).max() ?? -1) + 1
                generation = .generating
            }
            if let summaryID = role.summaryConnectionID {
                summaryTasks.configure(callID: saved.id, role: role, connection: connections.first { $0.id == summaryID })
            }
            var page = try await external.events(connection: connection, callID: saved.id, after: saved.externalEventCursor ?? 0)
            guard session == identity else { return }
            guard page.call.id == saved.id, page.call.contact_id == saved.externalRoleID,
                  page.call.source == role.effectiveCallMode.rawValue else {
                throw TincallError(message: String(localized: "远端通话标识不匹配"))
            }
            if page.call.status == "ended" {
                // Recover late text into the durable record without replaying an already-ended call.
                playback = .failed
                while true {
                    try receiveExternalPage(page, session: identity)
                    if !page.has_more { break }
                    page = try await external.events(connection: connection, callID: saved.id, after: records[saved.id]?.externalEventCursor ?? 0)
                }
                if session == identity { endFromExternal(identity) }
                return
            }
            guard page.call.status == "active" else { throw TincallError(message: String(localized: "请从来电页面接听此通话")) }
            // Keep the last persisted epoch until queued events have been consumed.
            voice.setSpeechInterruptionEnabled(speechInterruptionEnabled)
            let audio = VoiceConfiguration(stt: stt, tts: tts, voiceID: resolvedVoiceID(role: role, tts: tts), retention: retention)
            if let onStartOutgoingAudio { try await onStartOutgoingAudio(identity, role, audio) }
            else { try await voice.start(session: identity, configuration: audio) }
            guard session == identity else { return }
            phase = .active
            startActivityCheckpoints(identity)
            isMuted = false
            if let turn = turns[saved.id], generation == .generating {
                playback = .synthesizing
                try voice.beginReply(turn)
            }
            externalConnectionLost = false
            startExternalEvents(session: identity, connection: connection)
            sendExternalInput(callID: saved.id)
            sendExternalControl(callID: saved.id)
            beginQueuedInput()
        } catch {
            guard session == restoringIdentity else { return }
            if let restoringIdentity { stopActivityCheckpoints(restoringIdentity) }
            voice.stop()
            session = nil
            phase = .failed
            isUserSpeaking = false
            isAwaitingSpeechTranscript = false
            mutate(saved.id) { $0.endedAbnormally = true }
            persist(saved.id)
            errorMessage = safeMessage(error)
        }
    }
}
