// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

extension CallCoordinator {
    func requestSpeechRecognitionConnection(_ connection: ConnectionProfile) {
        guard phase == .active, !textOnly, !isSwitchingSpeechRecognition,
              !originalAudioInputEnabled, pendingOriginalAudioInputEnabled != true,
              connection.provider.isSpeechRecognition else { return }
        speechRecognitionError = nil
        pendingSpeechRecognitionConnection = connection.id == speechRecognitionConnectionID ? nil : connection
        applyPendingSpeechRecognitionConnection()
    }

    func requestOriginalAudioInput(_ enabled: Bool, connections: [ConnectionProfile]) {
        guard phase == .active, !textOnly, !isSwitchingSpeechRecognition else { return }
        speechRecognitionError = nil
        guard !enabled || supportsOriginalAudioInput else {
            speechRecognitionError = String(localized: "原声输入目前支持 Gemini 和 OpenAI 兼容模型直连，请确认模型及连接服务支持音频输入。")
            return
        }
        if enabled == originalAudioInputEnabled {
            pendingOriginalAudioInputEnabled = nil
            pendingSpeechRecognitionConnection = nil
            return
        }
        if enabled {
            guard let previous = connections.first(where: { $0.id == speechRecognitionConnectionID }) else { return }
            textRecognitionConnection = previous
            pendingSpeechRecognitionConnection = connections.first { $0.provider == .appleSpeech }
                ?? ConnectionProfile(name: String(localized: "Apple 本机识别"), provider: .appleSpeech, language: "zh-CN")
        } else {
            guard let previous = textRecognitionConnection else { return }
            pendingSpeechRecognitionConnection = previous
        }
        pendingOriginalAudioInputEnabled = enabled
        applyPendingSpeechRecognitionConnection()
    }

    private func applyPendingSpeechRecognitionConnection() {
        guard phase == .active, let identity = session, !textOnly,
              !isSwitchingSpeechRecognition, muteTransitionID == nil,
              !isUserSpeaking, !isAwaitingSpeechTranscript, partialTranscript.isEmpty, partialInput == nil,
              let connection = pendingSpeechRecognitionConnection else { return }
        let audioMode = pendingOriginalAudioInputEnabled
        isSwitchingSpeechRecognition = true
        speechRecognitionTask = Task { [weak self] in
            guard let self else { return }
            // A fresh utterance may have arrived before this task got actor time.
            guard self.session == identity else { return }
            defer {
                if self.session == identity {
                    self.isSwitchingSpeechRecognition = false
                    self.speechRecognitionTask = nil
                }
            }
            guard !self.isUserSpeaking, !self.isAwaitingSpeechTranscript, self.partialTranscript.isEmpty, self.partialInput == nil else { return }
            do {
                try await self.voice.setSpeechRecognitionConnection(connection)
                guard self.session == identity, !Task.isCancelled else { return }
                self.speechRecognitionConnectionID = connection.id
                if let audioMode {
                    self.originalAudioInputEnabled = audioMode
                } else {
                    do { try self.onSpeechRecognitionUsed?(connection.id) }
                    catch { self.speechRecognitionError = self.safeMessage(error) }
                }
            } catch {
                guard self.session == identity, !Task.isCancelled else { return }
                self.speechRecognitionError = self.safeMessage(error)
            }
            self.pendingSpeechRecognitionConnection = nil
            self.pendingOriginalAudioInputEnabled = nil
        }
    }

    func resetSpeechRecognitionSelection(_ id: UUID? = nil) {
        speechRecognitionTask?.cancel()
        speechRecognitionTask = nil
        speechRecognitionConnectionID = id
        pendingSpeechRecognitionConnection = nil
        isSwitchingSpeechRecognition = false
        speechRecognitionError = nil
        originalAudioInputEnabled = false
        pendingOriginalAudioInputEnabled = nil
        textRecognitionConnection = nil
        pendingInputAudio.removeAll()
    }

    func setSpeechInterruptionEnabled(_ enabled: Bool) {
        speechInterruptionEnabled = enabled
        voice.setSpeechInterruptionEnabled(enabled)
    }

    func setTextInputActive(_ active: Bool) {
        let active = active && phase == .active
        guard isTextInputActive != active else { return }
        isTextInputActive = active
        if active { isUserSpeaking = false; isAwaitingSpeechTranscript = false }
        // Temporary input suspension never changes the user's mute choice.
        voice.setTextInputActive(active)
        if active { partialTranscript = ""; partialInput = nil }
        applyPendingSpeechRecognitionConnection()
    }

    func toggleMute() async {
        guard phase == .active, let session, muteTransitionID == nil, !isSwitchingSpeechRecognition else { return }
        let transitionID = UUID()
        muteTransitionID = transitionID
        defer {
            if muteTransitionID == transitionID { muteTransitionID = nil }
            applyPendingSpeechRecognitionConnection()
        }
        let previous = isMuted
        let muted = !previous
        isMuted = muted
        if muted { isUserSpeaking = false; isAwaitingSpeechTranscript = false }
        // Present the tap before applying the input pause policy.
        await Task.yield()
        guard self.session == session, muteTransitionID == transitionID else { return }
        do {
            try await voice.setMicrophoneMuted(muted)
            guard self.session == session else { return }
            isMuted = muted
            if muted { partialTranscript = ""; partialInput = nil }
        } catch {
            if self.session == session, muteTransitionID == transitionID {
                isMuted = previous
                errorMessage = safeMessage(error)
            }
        }
    }

    func toggleSpeaker() async {
        guard phase == .active, let session, speakerTransitionID == nil else { return }
        let transitionID = UUID()
        speakerTransitionID = transitionID
        defer { if speakerTransitionID == transitionID { speakerTransitionID = nil } }
        let previous = isSpeakerEnabled
        let enabled = !previous
        speakerStateDuringTransition = nil
        isSpeakerEnabled = enabled
        await Task.yield()
        guard self.session == session, phase == .active else { return }
        do {
            try await voice.setSpeakerEnabled(enabled)
            guard self.session == session else { return }
            isSpeakerEnabled = speakerStateDuringTransition ?? enabled
        } catch {
            if self.session == session {
                isSpeakerEnabled = speakerStateDuringTransition ?? previous
                errorMessage = safeMessage(error)
            }
        }
    }

    func receive(_ event: VoiceEvent) {
        defer { applyPendingSpeechRecognitionConnection() }
        switch event {
        case let .speechActivity(identity, speaking):
            guard session == identity else { return }
            isUserSpeaking = speaking && phase == .active && !isMuted && !isTextInputActive
            if isUserSpeaking { modelEndTurn = nil }
            if isUserSpeaking, partialTranscript.isEmpty { isAwaitingSpeechTranscript = true }
        case let .transcript(identity, result):
            guard session == identity, phase == .active, !isTextInputActive,
                  !finalInputs.contains(result.inputID),
                  pendingFinalInputs[identity.callID]?.contains(where: { $0.id == result.inputID }) != true else { return }
            let result = result.corrected(using: transcriptCorrections())
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || result.isFinal || !isUserSpeaking { isAwaitingSpeechTranscript = false }
            if !text.isEmpty {
                CallAudioDiagnostics.record(.transcriptReceived, turn: turns[identity.callID]?.turnID,
                                            input: result.inputID, count: text.count, flag: result.isFinal)
            }
            if !text.isEmpty { floatingUserTranscript = text }
            let shouldInterrupt = !isAwaitingMCPReply && speechInterruptionEnabled && !isMuted && !text.isEmpty &&
                !interruptedSpeechInputs.contains(result.inputID) && canInterrupt
            if !result.isFinal {
                partialTranscript = result.text
                partialInput = text.isEmpty ? nil : result
                if shouldInterrupt {
                    CallAudioDiagnostics.record(.autoPartialInterrupt, turn: turns[identity.callID]?.turnID, input: result.inputID)
                    interruptedSpeechInputs.insert(result.inputID)
                    interrupt(automatically: true)
                }
                return
            }
            partialInput = nil
            guard !text.isEmpty else { partialTranscript = ""; return }
            // User audio and final transcription share one stable message ID.
            let user = CallMessage(id: result.inputID, turnID: UUID(), role: .user, text: text)
            if originalAudioInputEnabled {
                // Missing audio fails the model request explicitly; never silently substitute the transcript.
                pendingInputAudio[user.id] = result.audio ?? Data()
            }
            let interruptedTurn = shouldInterrupt ? turns[identity.callID] : nil
            guard accept(user, callID: identity.callID, queued: true, interrupting: interruptedTurn) else {
                pendingFinalInputs[identity.callID, default: []].append(user)
                partialTranscript = result.text
                return
            }
            finalInputs.insert(result.inputID)
            partialTranscript = ""
            if interruptedTurn != nil {
                CallAudioDiagnostics.record(.autoFinalInterrupt, turn: interruptedTurn?.turnID, input: result.inputID)
                interruptedSpeechInputs.insert(result.inputID)
                interrupt(automatically: true)
            } else { beginQueuedInput() }
        case let .microphoneState(identity, muted):
            guard session == identity else { return }
            isMuted = muted
            if muted { isUserSpeaking = false; isAwaitingSpeechTranscript = false }
            if muted { partialTranscript = ""; partialInput = nil }
        case let .speakerState(identity, enabled):
            guard session == identity else { return }
            if speakerTransitionID != nil { speakerStateDuringTransition = enabled }
            else { isSpeakerEnabled = enabled }
        case let .playback(turn, state):
            guard session == turn.session, turns[turn.session.callID] == turn, phase == .active else { return }
            playback = state
            if state == .failed, modelEndTurn == turn { modelEndTurn = nil }
            if state == .playing { floatingUserTranscript = "" }
            if (state == .drained || (state == .failed && externalEndSession == nil)), beginQueuedExternalReply() { return }
            if (state == .drained || state == .failed), externalEndSession == turn.session {
                if state == .failed { errorMessage = String(localized: "播放失败") }
                endFromExternal(turn.session)
                return
            }
            if state == .drained || state == .failed {
                currentPlaybackCaption = nil
                if state == .drained, finishModelEndIfReady(turn) { return }
                beginQueuedInput()
            }
        case let .playbackCaption(turn, caption):
            guard session == turn.session, turns[turn.session.callID] == turn, phase == .active else { return }
            currentPlaybackCaption = caption
        case let .speechInterruptionAvailability(identity, availability):
            guard session == identity else { return }
            speechInterruptionAvailability = availability
        case let .audioReady(identity, asset):
            guard sessions[identity.callID] == identity, records[identity.callID] != nil else {
                errorMessage = String(localized: "收到无关联通话的录音，源文件已保留")
                return
            }
            if pendingAudio[identity.callID]?.contains(where: { $0.id == asset.id }) != true {
                let adjusted = VoiceAudioSegment(id: asset.id, messageID: asset.messageID,
                    segmentIndex: asset.segmentIndex + (audioSegmentOffsets[asset.messageID] ?? 0),
                    fileURL: asset.fileURL, duration: asset.duration)
                pendingAudio[identity.callID, default: []].append(adjusted)
            }
            persistAudio(identity.callID)
        case let .failure(identity, message):
            guard session == identity else { return }
            errorMessage = message
        }
    }
}
