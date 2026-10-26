// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import Foundation

extension CallCoordinator {
    func sendExternalInput(callID: UUID) {
        guard tasks[callID] == nil, let value = records[callID], let pending = value.externalPendingInput,
              value.externalPendingControl == nil,
              let source = externalConnections[callID], let turn = turns[callID],
              let input = value.messages.first(where: { $0.id == pending.messageID }) else { return }
        do { try save(value) }
        catch { reportSavingFailure(error, callID: callID); return }
        tasks[callID] = Task { [weak self, external] in
            do {
                guard let self else { return }
                let data = try self.loadImages(input, callID: callID)
                let images = try ConnectorMessageImage.inputs(assets: input.images ?? [], data: data)
                let result = try await external.input(connection: source, callID: callID, pending: pending, text: input.text, images: images,
                    createdAt: input.createdAt)
                guard self.turns[callID] == turn else { return }
                guard result.call.id == callID, result.input_id == pending.messageID, result.epoch > pending.epoch else {
                    throw TincallError(message: String(localized: "连接端输入确认不匹配"))
                }
                if let knownReply = self.externalReplyIDs[callID], knownReply != result.reply_id {
                    throw TincallError(message: String(localized: "连接端回复标识不匹配"))
                }
                self.externalReplyIDs[callID] = result.reply_id
                self.mutate(callID) { $0.externalEpoch = max($0.externalEpoch ?? 0, result.epoch); $0.externalPendingInput = nil; $0.externalReplyID = result.reply_id }
                self.persist(callID)
                self.tasks.removeValue(forKey: callID)
                self.beginQueuedInput()
            } catch {
                guard !Task.isCancelled, let self, self.turns[callID] == turn else { return }
                self.tasks.removeValue(forKey: callID)
                self.externalConnectionLost = true
                self.errorMessage = String(localized: "输入已保存，连接端尚未确认：\(self.safeMessage(error))")
            }
        }
    }

    func startExternalEvents(session identity: VoiceSessionID, connection: ConnectionProfile) {
        externalEventsTask?.cancel()
        externalEventsTask = Task { [weak self, external] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.session == identity, self.phase == .active else { return }
                let cursor = self.records[identity.callID]?.externalEventCursor ?? 0
                do {
                    let started = ContinuousClock.now
                    let page = try await external.events(connection: connection, callID: identity.callID, after: cursor, wait: true,
                        logContext: self.turns[identity.callID].map { RequestLogStore.shared.context(for: $0) })
                    let elapsed = started.duration(to: .now)
                    guard self.session == identity, !Task.isCancelled else { return }
                    try self.receiveExternalPage(page, session: identity)
                    failures = 0
                    self.externalConnectionLost = (self.records[identity.callID]?.externalPendingInput != nil && self.tasks[identity.callID] == nil) ||
                        (self.records[identity.callID]?.externalPendingControl != nil && self.externalControlTasks[identity.callID] == nil)
                    if !self.externalConnectionLost {
                        if let message = self.externalEventsError, self.errorMessage == message { self.errorMessage = nil }
                        self.externalEventsError = nil
                    }
                    // The call snapshot can be newer than this page. Drain pending pages before ending.
                    if page.call.status == "ended", !page.has_more, self.session == identity { self.endFromExternal(identity) }
                    if !page.has_more, !page.events.isEmpty || elapsed < .seconds(1) {
                        // Keep page pacing; only an empty page that already waited skips the sleep.
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    guard !Task.isCancelled, self.session == identity else { return }
                    failures += 1
                    self.externalConnectionLost = true
                    let message = String(localized: "连接暂时中断，已收到内容已保留：\(self.safeMessage(error))")
                    self.externalEventsError = message
                    self.errorMessage = message
                    guard failures < 3 else { return }
                    try? await Task.sleep(for: .seconds(failures * 2))
                }
            }
        }
    }

    func receiveExternalPage(_ page: ExternalEventPage, session identity: VoiceSessionID) throws {
        let cursor = records[identity.callID]?.externalEventCursor ?? 0
        guard page.call.id == identity.callID, page.cursor >= cursor else {
            throw TincallError(message: String(localized: "连接端事件游标或通话标识不匹配"))
        }
        for event in page.events {
            guard event.call_id == identity.callID else { throw TincallError(message: String(localized: "连接端事件归属不匹配")) }
            guard event.sequence > (records[identity.callID]?.externalEventCursor ?? 0) else { continue }
            guard event.sequence == (records[identity.callID]?.externalEventCursor ?? 0) + 1 else {
                throw TincallError(message: String(localized: "连接端事件存在缺口，已停止播放以便恢复"))
            }
            try receiveExternal(event, session: identity)
            mutate(identity.callID) { $0.externalEventCursor = event.sequence }
            persist(identity.callID)
        }
        guard page.cursor == (records[identity.callID]?.externalEventCursor ?? 0) else {
            throw TincallError(message: String(localized: "连接端事件游标跳过了未接收内容"))
        }
        if !page.has_more { mutate(identity.callID) { $0.externalEpoch = max($0.externalEpoch ?? 0, page.call.epoch) } }
    }

    private func receiveExternal(_ event: ExternalCallEvent, session identity: VoiceSessionID) throws {
        guard session == identity else { return }
        let id = identity.callID
        if event.type == "generation.cancel_result" {
            reportExternalCancellation(event.payload.code, callID: id)
            return
        }
        if event.type == "call.ended" {
            endFromExternal(identity, afterPlayback: event.payload.reason == "mcp_hangup")
            return
        }
        // Received complete replies remain durable while preceding audio drains.
        // A submitted start carries no content and must not replace that audio.
        if event.payload.submitted == true, records[id]?.callMode == .mcp,
           externalReplyIDs[id] != event.payload.reply_id,
           !textOnly, generation == .completed, playback != .drained, playback != .failed,
           records[id]?.externalPendingControl?.endsCall != true {
            if event.type == "reply.started" { return }
            if event.type == "reply.completed", let replyID = event.payload.reply_id, var value = records[id] {
                guard let text = event.payload.text else { throw TincallError(message: String(localized: "连接端完成事件缺少正文")) }
                let message = CallMessage(id: value.messages.contains { $0.id == replyID } ? UUID() : replyID,
                                          turnID: UUID(), role: .assistant, text: cleanExternalText(text), status: .completed)
                value.messages.append(message)
                value.externalEpoch = max(value.externalEpoch ?? 0, event.epoch)
                try save(value)
                records[id] = value
                externalReplyQueue.append((VoiceTurnID(session: identity, turnID: message.turnID, messageID: message.id), replyID, event.payload.input_id))
                publish(id)
                return
            }
        }
        // A complete MCP submission is a new message, even after playback was interrupted.
        if (event.type == "reply.started" || event.type == "reply.completed"), event.payload.submitted == true,
           records[id]?.callMode == .mcp,
           let replyID = event.payload.reply_id, var value = records[id],
           !(externalReplyIDs[id] == replyID && turns[id].map { current in value.messages.contains { $0.id == current.messageID && $0.status == .generating } } == true),
           value.externalPendingControl?.endsCall != true {
            if let previous = turns[id], let index = value.messages.firstIndex(where: { $0.id == previous.messageID && $0.status == .generating }) {
                value.messages[index].status = .interrupted
                value.messages[index].interruption = .interrupt
            }
            let assistant = CallMessage(id: value.messages.contains(where: { $0.id == replyID }) ? UUID() : replyID, turnID: UUID(), role: .assistant, text: "", status: .generating)
            let turn = VoiceTurnID(session: identity, turnID: assistant.turnID, messageID: assistant.id)
            value.messages.append(assistant)
            value.externalReplyID = replyID
            value.externalEpoch = max(value.externalEpoch ?? 0, event.epoch)
            value.externalPendingControl = nil
            try save(value)
            records[id] = value
            turns[id] = turn
            externalReplyIDs[id] = replyID
            externalInputIDs[id] = event.payload.input_id
            publish(id)
            generation = .generating
            playback = textOnly ? .idle : .synthesizing
            currentPlaybackCaption = nil
            if !textOnly {
                do { try voice.beginReply(turn) }
                catch { playback = .failed; errorMessage = safeMessage(error) }
            }
        }
        // An opening reply has a server target but no user input. Only an explicit
        // epoch-zero started event may create it; late greetings cannot replace a user turn.
        if event.type == "reply.started", event.payload.opening == true,
           event.payload.input_id == nil, event.epoch == 0, (records[id]?.externalEpoch ?? 0) == 0,
           let replyID = event.payload.reply_id, var value = records[id],
           value.externalPendingInput == nil, value.externalPendingControl == nil,
           !value.messages.contains(where: { $0.role == .user || $0.id == replyID }), turns[id] == nil {
            let assistant = CallMessage(id: replyID, turnID: UUID(), role: .assistant, text: "", status: .generating)
            let turn = VoiceTurnID(session: identity, turnID: assistant.turnID, messageID: assistant.id)
            value.messages.append(assistant)
            value.externalReplyID = replyID
            try save(value)
            records[id] = value
            turns[id] = turn
            externalReplyIDs[id] = replyID
            externalInputIDs.removeValue(forKey: id)
            publish(id)
            generation = .generating
            playback = textOnly ? .idle : .synthesizing
            currentPlaybackCaption = nil
            if !textOnly {
                do { try voice.beginReply(turn) }
                catch { playback = .failed; errorMessage = safeMessage(error) }
            }
        }
        guard event.type.hasPrefix("reply."),
              let turn = turns[id],
              event.payload.input_id == externalInputIDs[id], let replyID = event.payload.reply_id,
              event.payload.input_id != nil || externalReplyIDs[id] == replyID,
              records[id]?.messages.first(where: { $0.id == turn.messageID })?.status == .generating,
              (event.payload.submitted == true && records[id]?.callMode == .mcp) || event.epoch >= (records[id]?.externalEpoch ?? 0) else { return }
        if let known = externalReplyIDs[id], known != replyID {
            complete(turn, status: .failed, error: TincallError(message: String(localized: "连接端在同一轮中替换回复标识，当前音频已停止")))
            return
        }
        externalReplyIDs[id] = replyID
        mutate(id) { $0.externalEpoch = max($0.externalEpoch ?? 0, event.epoch); $0.externalPendingInput = nil; $0.externalReplyID = replyID }
        switch event.type {
        case "reply.started":
            break
        case "reply.delta":
            guard let delta = event.payload.delta else { throw TincallError(message: String(localized: "连接端增量缺少文字")) }
            if role?.timeAwarenessEnabled == true {
                if externalTimestampFilter?.turn != turn {
                    var filter = CallTimestampStreamFilter()
                    // A resumed reply can already contain accepted text. Restore its line position.
                    _ = filter.append(records[id]?.messages.first(where: { $0.id == turn.messageID })?.text ?? "")
                    externalTimestampFilter = (turn, filter)
                }
                let text = externalTimestampFilter?.filter.append(delta) ?? ""
                if !text.isEmpty { receiveDelta(text, turn: turn) }
            } else { receiveDelta(delta, turn: turn) }
        case "reply.completed":
            guard let raw = event.payload.text else { throw TincallError(message: String(localized: "连接端完成事件缺少正文")) }
            let text = cleanExternalText(raw)
            let received = records[id]?.messages.first(where: { $0.id == turn.messageID })?.text ?? ""
            guard text.hasPrefix(received) else {
                complete(turn, status: .failed, error: TincallError(message: String(localized: "连接端完成正文与已接收内容不同，已停止合成")))
                return
            }
            receiveDelta(String(text.dropFirst(received.count)), turn: turn)
            mutate(id) { $0.externalPendingInput = nil }
            complete(turn, status: .completed)
        case "reply.failed":
            mutate(id) { $0.externalPendingInput = nil }
            complete(turn, status: .failed, error: TincallError(message: String(localized: "外部平台生成失败，请检查连接端状态")))
        case "reply.interrupted":
            cancelReply(turn, reason: event.payload.reason == "hangup" ? .hangUp : .interrupt)
            if !textOnly { voice.interruptReply(turn) }
            playback = .idle
            beginQueuedInput()
        default:
            throw TincallError(message: String(localized: "连接端返回不支持的回复事件"))
        }
    }

    private func cleanExternalText(_ text: String) -> String {
        role?.timeAwarenessEnabled == true ? CallTimestampStreamFilter.clean(text) : text
    }

    @discardableResult
    func beginQueuedExternalReply() -> Bool {
        guard let identity = session, phase == .active, !textOnly,
              playback == .drained || playback == .failed else { return false }
        while !externalReplyQueue.isEmpty {
            let next = externalReplyQueue.removeFirst()
            guard next.turn.session == identity,
                  let message = records[identity.callID]?.messages.first(where: { $0.id == next.turn.messageID }) else { continue }
            turns[identity.callID] = next.turn
            externalReplyIDs[identity.callID] = next.replyID
            externalInputIDs[identity.callID] = next.inputID
            mutate(identity.callID) { $0.externalReplyID = next.replyID }
            generation = .completed
            playback = .synthesizing
            currentPlaybackCaption = nil
            do {
                try voice.beginReply(next.turn)
                try voice.appendReply(message.text, to: next.turn)
                try voice.finishReply(next.turn)
                return true
            } catch {
                // The voice service may emit failure synchronously before throwing.
                // Its callback can already have advanced the queue or ended the call.
                guard session == identity, turns[identity.callID] == next.turn else { return true }
                playback = .failed
                errorMessage = safeMessage(error)
                voice.interruptReply(next.turn)
                playback = .failed
                if externalEndSession == identity { endFromExternal(identity); return true }
            }
        }
        return false
    }

    func discardQueuedExternalReplies(reason: MessageInterruption) {
        let queued = externalReplyQueue
        externalReplyQueue.removeAll()
        for next in queued {
            mutate(next.turn.session.callID) { value in
                guard let index = value.messages.firstIndex(where: { $0.id == next.turn.messageID }) else { return }
                value.messages[index].status = .interrupted
                value.messages[index].interruption = reason
            }
        }
    }

    func endFromExternal(_ identity: VoiceSessionID, afterPlayback: Bool = false) {
        guard session == identity else { return }
        // The server has closed generation. Keep the current audio until its
        // explicit drain event, including synthesis and gaps between segments.
        if afterPlayback { externalEndSession = identity }
        externalConnections.removeValue(forKey: identity.callID)
        if externalEndSession == identity, phase == .active, !textOnly,
           turns[identity.callID] != nil, generation == .completed,
           playback != .drained, playback != .failed {
            externalEventsTask?.cancel()
            externalEventsTask = nil
            return
        }
        // The regular local shutdown preserves partial transcription and received audio.
        hangUp(remotely: true)
    }

    func enqueueExternalControl(callID: UUID, endsCall: Bool) {
        guard externalConnections[callID] != nil, records[callID]?.externalCallID != nil else { return }
        if let pending = records[callID]?.externalPendingControl, pending.endsCall || !endsCall {
            sendExternalControl(callID: callID)
            return
        }
        mutate(callID) {
            $0.externalPendingInput = nil
            $0.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: $0.externalEpoch ?? 0, endsCall: endsCall)
        }
        persist(callID)
        sendExternalControl(callID: callID)
    }

    func sendExternalControl(callID: UUID) {
        guard externalControlTasks[callID] == nil, let connection = externalConnections[callID],
              let pending = records[callID]?.externalPendingControl else { return }
        do { if let value = records[callID] { try save(value) } }
        catch { reportSavingFailure(error, callID: callID); return }
        externalControlTasks[callID] = Task { [weak self, external] in
            defer { self?.externalControlTasks.removeValue(forKey: callID) }
            do {
                guard let self else { return }
                var current = pending
                var isEnded = false
                if pending.prepared != true {
                    // Freeze and persist the first sent payload; idempotency checks include its epoch.
                    let page = try await external.events(connection: connection, callID: callID, after: self.records[callID]?.externalEventCursor ?? 0)
                    isEnded = page.call.status == "ended"
                    current = ExternalPendingControl(requestID: pending.requestID, epoch: page.call.epoch, endsCall: pending.endsCall, prepared: true)
                    if self.records[callID]?.externalPendingControl?.requestID == pending.requestID {
                        self.mutate(callID) { $0.externalPendingControl = current }
                        if let value = self.records[callID] { try self.save(value) }
                    }
                }
                if !isEnded {
                    let result = try await external.control(connection: connection, callID: callID, pending: current, confirmCancellation: false)
                    isEnded = result.status == "ended"
                    self.mutate(callID) { $0.externalEpoch = max($0.externalEpoch ?? 0, result.epoch) }
                    if result.source == "backend" {
                        // Confirmation must not hold the control slot: a manual
                        // hangup can immediately supersede an earlier interrupt.
                        let epoch = current.epoch
                        Task { [weak self, external] in
                            let code: String?
                            do { code = try await external.cancellationResult(connection: connection, call: result, epoch: epoch) }
                            catch { code = "cancel_unconfirmed" }
                            guard !Task.isCancelled else { return }
                            self?.reportExternalCancellation(code, callID: callID)
                        }
                    }
                }
                if self.records[callID]?.externalPendingControl?.requestID == pending.requestID {
                    self.mutate(callID) { $0.externalPendingControl = nil }
                    self.persist(callID)
                    if isEnded, let identity = self.session, identity.callID == callID { self.endFromExternal(identity) }
                    else { self.beginQueuedInput() }
                } else {
                    // A hangup can supersede an in-flight interrupt; dispatch the newer action after this task releases its slot.
                    Task { [weak self] in self?.sendExternalControl(callID: callID) }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                if let failure = error as? ExternalCallFailure, failure.code == "call_not_found" || failure.code == "call_ended",
                   self.records[callID]?.externalPendingControl?.requestID == pending.requestID {
                    self.mutate(callID) { $0.externalPendingControl = nil }
                    self.persist(callID)
                    if let identity = self.session, identity.callID == callID { self.endFromExternal(identity) }
                    return
                }
                if let failure = error as? ExternalCallFailure, failure.code == "stale_epoch",
                   self.records[callID]?.externalPendingControl?.requestID == pending.requestID {
                    // A rejected stale action was never executed; a new request may refresh the epoch.
                    self.mutate(callID) { $0.externalPendingControl = ExternalPendingControl(requestID: UUID(), epoch: $0.externalEpoch ?? 0, endsCall: pending.endsCall) }
                    self.persist(callID)
                    // The current worker still owns the send slot. Retry after
                    // it releases the slot so a local hangup cannot remain
                    // active in the connector indefinitely.
                    Task { [weak self] in self?.sendExternalControl(callID: callID) }
                }
                self.externalConnectionLost = true
                if self.record?.id == callID { self.errorMessage = String(localized: "本机已停止，连接端取消尚未确认，请恢复连接重试：\(self.safeMessage(error))") }
            }
        }
    }

    private func reportExternalCancellation(_ code: String?, callID: UUID) {
        guard let code, code != "cancel_accepted", record?.id == callID else { return }
        errorMessage = String(localized: "本机已停止，但后端尚未确认取消生成，请检查后端取消接口。")
    }

    func reconnectExternal() {
        guard let session, let connection = externalConnections[session.callID] else {
            if let id = record?.id { sendExternalControl(callID: id) }
            return
        }
        externalConnectionLost = false
        startExternalEvents(session: session, connection: connection)
        sendExternalInput(callID: session.callID)
        sendExternalControl(callID: session.callID)
    }

    /// Restore persisted cancellation outbox on launch without starting capture or sending unsent input.
    func restorePendingExternalControls(from values: [CallRecord], connections: [ConnectionProfile]) {
        for value in values where value.externalPendingControl != nil {
            guard let connection = connections.first(where: { $0.id == value.externalConnectionID && $0.provider == .genericConnector }) else { continue }
            if records[value.id] == nil { records[value.id] = value }
            externalConnections[value.id] = connection
            sendExternalControl(callID: value.id)
        }
    }

    /// Accept the remote invitation while CallKit still owns its temporary system call; do not start audio here.
    /// Starts the opening while CallKit rings, without recording or activating the microphone.
}
