// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

extension CallCoordinator {
    var isAwaitingMCPReply: Bool {
        guard record?.callMode == .mcp, generation == .generating, playback != .playing,
              let id = record?.id, let turn = turns[id],
              let message = record?.messages.first(where: { $0.id == turn.messageID }) else { return false }
        return message.status == .generating && message.text.isEmpty
    }
    private var canBeginTurn: Bool {
        canSend && externalReplyQueue.isEmpty &&
        (isAwaitingMCPReply || (generation != .generating && playback != .playing && playback != .synthesizing)) &&
        record?.externalPendingInput == nil && record?.externalPendingControl == nil
    }
    /// UI clears its draft only after this function actually accepts and saves input.
    @discardableResult
    func sendText(_ text: String, images: [Data] = []) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty || !images.isEmpty, let session else { return false }
        guard images.count <= 4 else { errorMessage = String(localized: "一次最多发送 4 张图片"); return false }
        var user = CallMessage(turnID: UUID(), role: .user, text: text)
        if !images.isEmpty {
            do {
                guard let onSaveImages else { throw TincallError(message: String(localized: "无法保存消息图片")) }
                user.images = try onSaveImages(session.callID, user.id, images)
            } catch { errorMessage = safeMessage(error); return false }
        }
        let interruptedTurn = canInterrupt && !isAwaitingMCPReply ? turns[session.callID] : nil
        // Persist both the input and cancellation intent before stopping the old reply.
        guard accept(user, callID: session.callID, queued: true, interrupting: interruptedTurn) else {
            if let assets = user.images {
                do { try onDiscardImages?(session.callID, user.id, assets) }
                catch { errorMessage = safeMessage(error) }
            }
            return false
        }
        if interruptedTurn != nil { interrupt() }
        else { beginQueuedInput() }
        return true
    }

    func loadImages(_ message: CallMessage, callID: UUID?) throws -> [Data] {
        guard message.images?.isEmpty == false else { return [] }
        guard let callID, let onLoadImages else { throw TincallError(message: String(localized: "无法读取消息图片")) }
        return try onLoadImages(callID, message)
    }

    func interrupt(automatically: Bool = false) {
        if let identity = externalEndSession, session == identity {
            externalEndSession = nil
            endFromExternal(identity)
            return
        }
        guard let id = record?.id, let turn = turns[id], canInterrupt else { return }
        if !automatically { CallAudioDiagnostics.record(.manualInterrupt, turn: turn.turnID) }
        cancelReply(turn, reason: .interrupt)
        if !textOnly { voice.interruptReply(turn) }
        playback = .idle
        currentPlaybackCaption = nil
        persist(id)
        enqueueExternalControl(callID: id, endsCall: false)
        if let identity = session, let connection = externalConnections[id] {
            // Cancel the outstanding wait; the new loop keeps listening for this call.
            startExternalEvents(session: identity, connection: connection)
        }
        beginQueuedInput()
    }

    func cancelReply(_ turn: VoiceTurnID, reason: MessageInterruption) {
        let id = turn.session.callID
        if externalTimestampFilter?.turn == turn { externalTimestampFilter = nil }
        if modelEndTurn == turn { modelEndTurn = nil }
        discardQueuedExternalReplies(reason: reason)
        // A completed reply can still be in the TTS synthesis queue. Stopping
        // that queue before its first playback callback is not an interrupted
        // audible reply, so keep the completed message clean.
        let shouldRecordInterruption = generation != .completed || playback == .playing
        // Invalidate before cancellation, so delayed deltas cannot affect this or a later turn.
        turns.removeValue(forKey: id)
        tasks.removeValue(forKey: id)?.cancel()
        mutate(id) { value in
            value.externalPendingInput = nil
            guard shouldRecordInterruption,
                  let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) else { return }
            value.messages[index].status = .interrupted
            value.messages[index].interruption = reason
        }
        if !shouldRecordInterruption {
            generation = .completed
        } else {
            generation = .interrupted
        }
        if session == turn.session { currentPlaybackCaption = nil }
    }

    private enum Hello {
        static let word = "hello"
    }

    func accept(_ user: CallMessage, callID: UUID, queued: Bool = false, interrupting turn: VoiceTurnID? = nil) -> Bool {
        guard var value = records[callID] else { return false }
        if modelEndTurn?.session.callID == callID { modelEndTurn = nil }
        if !value.messages.contains(where: { $0.id == user.id }) { value.messages.append(user) }
        if queued, value.queuedInputIDs?.contains(user.id) != true {
            value.queuedInputIDs = (value.queuedInputIDs ?? []) + [user.id]
        }
        if let turn {
            value.externalPendingInput = nil
            if let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) {
                value.messages[index].status = .interrupted
                value.messages[index].interruption = .interrupt
            }
            if externalConnections[callID] != nil, value.externalCallID != nil, value.externalPendingControl == nil {
                value.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: value.externalEpoch ?? 0, endsCall: false)
            }
        }
        do {
            try save(value)
            records[callID] = value
            publish(callID)
            persistAudio(callID)
            return true
        } catch { reportSavingFailure(error, callID: callID); return false }
    }

    private func beginTurn(_ user: CallMessage, session: VoiceSessionID) {
        guard let connection, let role, self.session == session, var value = records[session.callID] else { return }
        let assistant = CallMessage(turnID: user.turnID, role: .assistant, text: "", status: .generating)
        let turn = VoiceTurnID(session: session, turnID: user.turnID, messageID: assistant.id)
        value.messages.append(assistant)
        value.queuedInputIDs?.removeAll { $0 == user.id }
        if role.effectiveCallMode != .standalone {
            value.externalPendingInput = ExternalPendingInput(requestID: user.id, messageID: user.id,
                replyMessageID: assistant.id, epoch: value.externalEpoch ?? 0,
                timeZone: role.timeAwarenessEnabled == true ? TimeZone.autoupdatingCurrent.identifier : nil)
            value.externalReplyID = nil
        }
        do {
            try save(value)
        } catch {
            savingCallIDs.insert(session.callID)
            errorMessage = String(localized: "输入已保存，回复尚未开始，请重试保存：\(safeMessage(error))")
            return
        }
        records[session.callID] = value
        publish(session.callID)
        RequestLogStore.shared.registerTurn(callID: session.callID, inputID: user.id, turnID: user.turnID)
        turns[session.callID] = turn
        CallAudioDiagnostics.record(.turnBegan, turn: turn.turnID, input: user.id)
        errorMessage = nil
        generation = .generating
        playback = textOnly ? .idle : .synthesizing
        currentPlaybackCaption = nil
        if !textOnly {
            do { try voice.beginReply(turn) }
            catch { playback = .failed; errorMessage = safeMessage(error) }
        }
        let history = records[session.callID]?.messages.filter { $0.id != assistant.id && $0.createdAt <= user.createdAt } ?? []
        if role.effectiveCallMode != .standalone {
            externalInputIDs[session.callID] = user.id
            externalReplyIDs.removeValue(forKey: session.callID)
            sendExternalInput(callID: session.callID)
            return
        }
        let audio = pendingInputAudio.removeValue(forKey: user.id)
        let context: CallContext
        do { context = try CallContextBuilder.build(role: role, historyRecords: historyRecords, currentMessages: history, ttsConnection: ttsConnection,
            userName: summaryUserName(),
            loadImages: { [self] message in try loadImages(message, callID: session.callID) },
            assistantInitiated: value.externalCallID != nil,
            audioInput: audio.map { (messageID: user.id, audio: $0) }) }
        catch { complete(turn, status: .failed, error: error); return }
        tasks[session.callID] = Task { [weak self, model] in
            do {
                var timestampFilter = CallTimestampStreamFilter()
                var endFilter = CallEndStreamFilter()
                let timeAware = role.timeAwarenessEnabled == true
                _ = try await model.stream(connection: connection, messages: context.messages, logContext: RequestLogStore.shared.context(for: turn),
                                           omittedTurnCount: context.omittedTurnCount) { delta in
                    let cleaned = endFilter.append(delta)
                    let text = timeAware ? timestampFilter.append(cleaned) : cleaned
                    if !text.isEmpty { self?.receiveDelta(text, turn: turn) }
                }
                let endTail = endFilter.append("", final: true)
                let tail = timeAware ? timestampFilter.append(endTail, final: true) : endTail
                if !tail.isEmpty { self?.receiveDelta(tail, turn: turn) }
                if endFilter.requestsEnd, self?.turns[session.callID] == turn {
                    self?.modelEndTurn = turn
                }
                self?.complete(turn, status: .completed)
            } catch {
                if Task.isCancelled { return }
                self?.complete(turn, status: .failed, error: error)
            }
        }
    }

    func receiveDelta(_ delta: String, turn: VoiceTurnID) {
        guard turns[turn.session.callID] == turn else { return }
        mutate(turn.session.callID) { value in
            if let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) { value.messages[index].text += delta }
        }
        // A shortcut can outlive its dialog; keep every received delta durable before suspension.
        if textOnly { persist(turn.session.callID); return }
        guard session == turn.session, phase == .active, playback != .failed else { return }
        do { try voice.appendReply(delta, to: turn) }
        catch { playback = .failed; errorMessage = safeMessage(error); voice.interruptReply(turn) }
    }

    func complete(_ turn: VoiceTurnID, status: MessageStatus, error: Error? = nil) {
        let id = turn.session.callID
        guard turns[id] == turn else { return }
        if externalTimestampFilter?.turn == turn { externalTimestampFilter = nil }
        CallAudioDiagnostics.record(.turnCompleted, turn: turn.turnID, flag: status == .completed)
        tasks.removeValue(forKey: id)
        mutate(id) { value in
            if let index = value.messages.firstIndex(where: { $0.id == turn.messageID }) { value.messages[index].status = status }
        }
        persist(id)
        guard session == turn.session || (record?.id == id && phase == .ended) else { return }
        generation = status == .completed ? .completed : .failed
        if status != .completed, modelEndTurn == turn { modelEndTurn = nil }
        if let error { errorMessage = safeMessage(error) }
        if session == turn.session, !textOnly {
            if status == .completed, playback != .failed {
                do { try voice.finishReply(turn) }
                catch { playback = .failed; errorMessage = safeMessage(error); voice.interruptReply(turn) }
            } else {
                voice.interruptReply(turn)
                playback = .failed
            }
            if finishModelEndIfReady(turn) { return }
            beginQueuedInput()
        } else if textOnly {
            _ = finishModelEndIfReady(turn)
        }
    }

    @discardableResult
    func finishModelEndIfReady(_ turn: VoiceTurnID) -> Bool {
        guard modelEndTurn == turn, turns[turn.session.callID] == turn, session == turn.session,
              generation == .completed, textOnly || playback == .drained else { return false }
        guard !isUserSpeaking, !isAwaitingSpeechTranscript, partialTranscript.isEmpty,
              pendingFinalInputs[turn.session.callID]?.isEmpty != false,
              records[turn.session.callID]?.queuedInputIDs?.isEmpty != false else {
            modelEndTurn = nil
            return false
        }
        hangUp(remotely: true)
        return true
    }

    func beginQueuedInput() {
        guard canBeginTurn, let session, let value = records[session.callID],
              let id = value.queuedInputIDs?.first,
              let user = value.messages.first(where: { $0.id == id && $0.role == .user }) else { return }
        // An acknowledged MCP input must not make later messages wait for an
        // assistant reply. Keep unsent inputs queued until their own acknowledgement.
        if isAwaitingMCPReply, let previous = turns[session.callID] {
            cancelReply(previous, reason: .interrupt)
            if !textOnly { voice.interruptReply(previous) }
        }
        beginTurn(user, session: session)
    }
}
