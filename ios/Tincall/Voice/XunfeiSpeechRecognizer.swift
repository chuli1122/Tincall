// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import AVFoundation
import CryptoKit
import Foundation

struct XunfeiCredentials {
    let xunfeiAppID: String
    let xunfeiAPIKey: String
    let xunfeiAPISecret: String
}

@MainActor
final class XunfeiSpeechRecognizer: SpeechRecognizer {
    var onSpeechActivityChange: ((Bool) -> Void)? {
        get { capture.onSpeechActivityChange }
        set { capture.onSpeechActivityChange = newValue }
    }
    private let credentials: XunfeiCredentials
    private let logContext: () -> RequestLogContext?
    private let connectionName: String?
    private var requestLog: RequestLogSpan?
    private var socket: URLSessionWebSocketTask?
    // Do not open a cloud recognition turn for a short cough/noise burst.
    // The gate retains the onset PCM until sustained speech is confirmed.
    private let capture = MicrophoneCapture(requiresSustainedSpeech: true)
    private var callback: ((String, Bool, Data?) async -> Void)?
    private var onError: ((Error) async -> Void)?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var generation = 0
    private var isRunning = false
    private var isTranscriptionPaused = false
    private var onReset: (() -> Void)?
    private var replayBuffer = STTReplayBuffer()
    private var sentAudioBytes = 0
    private var recognitionTimeout: Task<Void, Never>?
    private var hasDetectedSpeech = false
    private var hasReceivedTranscript = false
    // A 55-second connection rotation is not an utterance boundary. Keep the
    // completed segment here until Xunfei reports the actual silence boundary.
    private var utteranceTranscript = ""
    private var utteranceAudio = Data()
    private var sessionAudioCommitted = false
    private var rotationPending = false
    private var finishRequested = false
    private var silenceBytes = 0
    private var awaitingFinal = false
    private var pendingAudio = STTReplayBuffer()
    private var pendingHasSpeech = false
    private var signedAt: TimeInterval = 0
    private var reusedPreconnection = false

    init(credentials: XunfeiCredentials, logContext: @escaping () -> RequestLogContext? = { nil }, connectionName: String? = nil) {
        self.logContext = logContext
        self.connectionName = connectionName
        self.credentials = credentials
    }

    /// Snapshot before an immediate hangup clears the current recognition buffer.
    var currentInputAudio: Data {
        utteranceAudio + Data(replayBuffer.audio.prefix(sessionAudioCommitted ? 0 : sentAudioBytes)) + pendingAudio.audio
    }

    func start(callback: @escaping (String, Bool, Data?) async -> Void, onError: @escaping (Error) async -> Void = { _ in }, onReset: @escaping () -> Void = {}) async throws {
        stop()
        self.callback = callback
        self.onError = onError
        self.onReset = onReset
        isRunning = true
        waitForSpeech()
        try await capture.start(onAudio: { [weak self] filtered in
            guard let self else { return }
            await self.acceptVADAudio(filtered, generation: self.generation)
        }, onError: { [weak self] error in await self?.fail(error) })
    }

    func stopAndWait() async {
        stop()
        await capture.waitForStop()
    }

    func stop() {
        isRunning = false
        isTranscriptionPaused = false
        closeRecognitionSession()
        capture.stop()
        callback = nil
        onError = nil
        onReset = nil
        replayBuffer = STTReplayBuffer()
        utteranceTranscript = ""
        utteranceAudio = Data()
        rotationPending = false
        finishRequested = false
        silenceBytes = 0
        awaitingFinal = false
        pendingAudio = STTReplayBuffer()
        pendingHasSpeech = false
        hasReceivedTranscript = false
    }

    func finishRecording() throws -> Bool {
        capture.stop()
        guard socket != nil, hasDetectedSpeech else { closeRecognitionSession(); return false }
        finishRequested = true
        audioContinuation?.finish(); audioContinuation = nil
        armRecognitionTimeout()
        return true
    }

    private func acceptVADAudio(_ filtered: (audio: Data, hasSpeech: Bool), generation: Int) async {
        guard isRunning, !isTranscriptionPaused, self.generation == generation else { return }
        if awaitingFinal {
            // The provider may have already decided EOS. Never send the next
            // onset into a connection whose final result is still in flight.
            guard pendingHasSpeech || filtered.hasSpeech else { return }
            do { try pendingAudio.append(filtered.audio) }
            catch { await fail(error); return }
            pendingHasSpeech = pendingHasSpeech || filtered.hasSpeech
            return
        }
        if !hasDetectedSpeech {
            // A prepared socket sends no audio until actual speech. Reuse a live,
            // connecting/open socket only within a conservative signature window
            // (Xunfei permits 5 minutes); otherwise sign and connect afresh.
            guard filtered.hasSpeech else { return }
            if let socket, socket.state != .running || socket.closeCode != .invalid ||
                socket.error != nil || ProcessInfo.processInfo.systemUptime - signedAt >= 240 {
                closeRecognitionSession()
            }
            if socket != nil {
                reusedPreconnection = true
                hasDetectedSpeech = true
                beginRequestLog()
            }
        }
        if socket == nil {
            do { try openRecognitionSession(containsSpeech: true) }
            catch { await fail(error); return }
        }
        if filtered.hasSpeech {
            hasDetectedSpeech = true
            // A response deadline must not expire while the user is still speaking.
            armRecognitionTimeout()
        }
        guard !filtered.audio.isEmpty else { return }
        do {
            try replayBuffer.append(filtered.audio)
        } catch {
            await fail(error)
            return
        }
        if case .dropped = audioContinuation?.yield(filtered.audio) {
            await report(TincallError(message: String(localized: "语音上传过慢，请检查网络后重新打开麦克风")))
            return
        }
        silenceBytes = filtered.hasSpeech ? 0 : silenceBytes + filtered.audio.count
        if silenceBytes >= 16_000 * 2 * 2 {
            // Match the existing two-second utterance boundary, but keep
            // capturing while the sender drains and the final result arrives.
            awaitingFinal = true
            audioContinuation?.finish(); audioContinuation = nil
            armRecognitionTimeout()
        }
    }

    func resetRecognition() {
        guard isRunning else { return }
        waitForSpeech()
    }

    private func waitForSpeech(resetCapture: Bool = true) {
        let shouldPrepare = !finishRequested
        closeRecognitionSession()
        replayBuffer = STTReplayBuffer()
        hasDetectedSpeech = false
        utteranceTranscript = ""
        utteranceAudio.removeAll(keepingCapacity: true)
        rotationPending = false
        finishRequested = false
        silenceBytes = 0
        awaitingFinal = false
        pendingAudio = STTReplayBuffer()
        pendingHasSpeech = false
        hasReceivedTranscript = false
        if resetCapture { capture.reset() }
        onReset?()
        if shouldPrepare, isRunning, !isTranscriptionPaused {
            // Preparation is best effort, once per listening boundary. Never
            // send silence or reconnect repeatedly just to keep a socket alive.
            try? openRecognitionSession()
        }
    }

    private func armRecognitionTimeout() {
        recognitionTimeout?.cancel()
        let expectedGeneration = generation
        recognitionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.isRunning, self.generation == expectedGeneration, !self.isTranscriptionPaused else { return }
            if !self.hasReceivedTranscript {
                // VAD can open for a cough or other non-speech sound. End the
                // empty turn quietly and wait for a new confirmed onset.
                self.waitForSpeech(resetCapture: false)
                return
            }
            await self.report(TincallError(message: String(localized: "语音识别响应超时"), requestCode: "timeout"))
        }
    }

    func setTranscriptionPaused(_ paused: Bool) {
        guard isTranscriptionPaused != paused else { return }
        isTranscriptionPaused = paused
        capture.setPaused(paused)
        if paused {
            closeRecognitionSession()
            replayBuffer = STTReplayBuffer()
            utteranceTranscript = ""
            utteranceAudio = Data()
            rotationPending = false
            finishRequested = false
            silenceBytes = 0
            awaitingFinal = false
            pendingAudio = STTReplayBuffer()
            pendingHasSpeech = false
            hasReceivedTranscript = false
            onReset?()
        }
        if !paused, isRunning {
            // Discard delayed results from audio captured during playback.
            waitForSpeech()
        }
    }

    private func closeRecognitionSession() {
        requestLog?.response(socket?.response)
        requestLog?.finish(); requestLog = nil
        generation += 1
        recognitionTimeout?.cancel(); recognitionTimeout = nil
        audioContinuation?.finish()
        audioContinuation = nil
        senderTask?.cancel()
        receiverTask?.cancel()
        senderTask = nil
        receiverTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        reusedPreconnection = false
    }

    private func beginRequestLog() {
        let log = RequestLogStore.shared.begin(service: .xunfei, step: .transcription, context: logContext(),
                                              connectionName: connectionName)
        log.protect([credentials.xunfeiAPIKey, credentials.xunfeiAPISecret])
        log.request(String(localized: "PCM16 · 16 kHz · 单声道 · 0.00 秒"))
        requestLog = log
    }

    private func openRecognitionSession(replay: Data = Data(), containsSpeech: Bool? = nil,
                                        preserveUtterance: Bool = false) throws {
        guard isRunning, !isTranscriptionPaused else { return }
        closeRecognitionSession()
        replayBuffer = STTReplayBuffer()
        try replayBuffer.append(replay)
        // Connection setup is not a capture boundary: the onset already passed
        // VAD. Resetting here drops queued frames and closes the interruption gate.
        hasDetectedSpeech = containsSpeech ?? !replay.isEmpty
        sentAudioBytes = 0
        sessionAudioCommitted = false
        if !preserveUtterance {
            silenceBytes = 0
            awaitingFinal = false
            pendingAudio = STTReplayBuffer()
            pendingHasSpeech = false
            if !preserveUtterance { hasReceivedTranscript = false }
            onReset?()
        }
        guard let url = signedURL() else { throw TincallError(message: String(localized: "讯飞连接地址无效")) }
        signedAt = ProcessInfo.processInfo.systemUptime
        let sessionGeneration = generation
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(100)) { audioContinuation = $0 }
        if !replay.isEmpty { audioContinuation?.yield(replay) }
        // A manual stop during rotation must still transcribe the captured tail.
        if finishRequested || awaitingFinal { audioContinuation?.finish(); audioContinuation = nil }
        if hasDetectedSpeech { beginRequestLog() }
        task.resume()
        if !replay.isEmpty { armRecognitionTimeout() }
        senderTask = Task { [weak self] in
            guard let self else { return }
            var pending = Data()
            var first = true
            var sentBytes = 0
            let clock = ContinuousClock()
            var nextFrameAt: ContinuousClock.Instant?
            do {
                for await pcm in stream {
                    guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                    pending.append(pcm)
                    while pending.count >= 1280 {
                        let chunk = Data(pending.prefix(1280))
                        pending.removeFirst(1280)
                        if let nextFrameAt { try await clock.sleep(until: nextFrameAt) }
                        let frameStartedAt = try await self.sendFrame(chunk, status: first ? 0 : 1, on: task)
                        nextFrameAt = frameStartedAt.advanced(by: .milliseconds(40))
                        guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                        first = false
                        sentBytes += chunk.count
                        self.sentAudioBytes = sentBytes
                        if sentBytes == 1280 || sentBytes % 32_000 == 0 {
                            CallAudioDiagnostics.record(.sttAudioSent, generation: sessionGeneration,
                                count: sentBytes, phase: "xunfei")
                        }
                        self.requestLog?.request(String(format: String(localized: "PCM16 · 16 kHz · 单声道 · %.2f 秒"), Double(sentBytes) / 32000), persistImmediately: false)
                        // Pace from each actual send start. Socket/actor work is
                        // part of the 40 ms interval, not an extra accumulating delay.
                        // Xunfei limits each recognition connection to 60 seconds.
                        if sentBytes >= 16_000 * 2 * 55 {
                            self.rotationPending = true
                            self.audioContinuation = nil
                            self.armRecognitionTimeout()
                            try await self.sendFrame(Data(), status: 2, on: task)
                            return
                        }
                    }
                }
                guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                if !pending.isEmpty {
                    if let nextFrameAt { try await clock.sleep(until: nextFrameAt) }
                    try await self.sendFrame(pending, status: first ? 0 : 1, on: task)
                    guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                    self.sentAudioBytes += pending.count
                    self.requestLog?.request(String(format: String(localized: "PCM16 · 16 kHz · 单声道 · %.2f 秒"), Double(self.sentAudioBytes) / 32000), persistImmediately: false)
                }
                try await self.sendFrame(Data(), status: 2, on: task)
                guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                self.armRecognitionTimeout()
            } catch {
                if !Task.isCancelled, self.generation == sessionGeneration { await self.report(error) }
            }
        }
        receiverTask = Task { [weak self] in
            guard let self else { return }
            var transcript = XunfeiTranscript()
            do {
                while !Task.isCancelled, self.generation == sessionGeneration {
                    let message = try await task.receive()
                    guard self.generation == sessionGeneration else { return }
                    self.requestLog?.response(task.response)
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    let result: (text: String, isFinal: Bool)?
                    do { result = try transcript.consume(data) }
                    catch { self.requestLog?.body(data); throw error }
                    // Counts/timing only: distinguish a delayed provider result
                    // from an upload, parser or downstream caption delay.
                    CallAudioDiagnostics.record(.sttResponse, generation: sessionGeneration,
                        count: result?.text.count ?? 0, flag: result?.isFinal,
                        phase: result == nil ? "xunfei_empty" : (transcript.usesDynamicCorrections ? "xunfei_wpgs" : "xunfei_plain"))
                    guard let result else { continue }
                    guard self.hasDetectedSpeech else {
                        if result.isFinal { self.closeRecognitionSession(); return }
                        continue
                    }
                    self.requestLog?.text(result.text)
                    if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.hasReceivedTranscript = true
                    }
                    if result.isFinal { self.requestLog?.succeed(); self.requestLog?.finish() }
                    if !result.isFinal, self.hasDetectedSpeech, !result.text.isEmpty, !self.isTranscriptionPaused { self.armRecognitionTimeout() }
                    let shouldContinueUtterance = result.isFinal && self.rotationPending &&
                        ((!self.finishRequested && !self.awaitingFinal) || self.replayBuffer.audio.count > self.sentAudioBytes)
                    if !self.isTranscriptionPaused, self.hasDetectedSpeech {
                        if result.isFinal {
                            let segmentAudio = Data(self.replayBuffer.audio.prefix(self.sentAudioBytes))
                            self.rotationPending = false
                            self.utteranceAudio.append(segmentAudio)
                            self.sessionAudioCommitted = true
                            let combinedText = self.utteranceTranscript + result.text
                            if shouldContinueUtterance {
                                self.utteranceTranscript = combinedText
                                await self.callback?(combinedText, false, nil)
                            } else {
                                let combinedAudio = self.utteranceAudio
                                self.utteranceTranscript = ""
                                self.utteranceAudio.removeAll(keepingCapacity: true)
                                await self.callback?(combinedText, true, combinedAudio)
                            }
                        } else {
                            await self.callback?(self.utteranceTranscript + result.text, false, nil)
                        }
                    }
                    guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                    if result.isFinal {
                        let remainder = self.replayBuffer.take(after: self.sentAudioBytes)
                        self.audioContinuation?.finish()
                        self.senderTask?.cancel()
                        task.cancel(with: .normalClosure, reason: nil)
                        if self.isRunning, self.generation == sessionGeneration {
                            if shouldContinueUtterance {
                                try self.openRecognitionSession(replay: remainder, containsSpeech: true, preserveUtterance: true)
                            } else if self.pendingHasSpeech {
                                let nextAudio = remainder + self.pendingAudio.audio
                                try self.openRecognitionSession(replay: nextAudio, containsSpeech: true)
                            } else if !self.finishRequested, remainder.contains(where: { $0 != 0 }) {
                                try self.openRecognitionSession(replay: remainder)
                            }
                            else { self.waitForSpeech(resetCapture: false) }
                        }
                        return
                    }
                }
            } catch {
                if !Task.isCancelled, self.generation == sessionGeneration { await self.report(error) }
            }
        }
    }

    @discardableResult
    private func sendFrame(_ pcm: Data, status: Int, on socket: URLSessionWebSocketTask) async throws -> ContinuousClock.Instant {
        var frame: [String: Any] = ["data": ["status": status, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": pcm.base64EncodedString()]]
        if status == 0 {
            frame["common"] = ["app_id": credentials.xunfeiAppID]
            frame["business"] = ["language": "zh_cn", "domain": "iat", "accent": "mandarin", "dwa": "wpgs", "eos": 2000]
        }
        let data = try JSONSerialization.data(withJSONObject: frame)
        return try await sendSocketMessage(.string(String(decoding: data, as: UTF8.self)), on: socket)
    }

    private func sendSocketMessage(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) async throws -> ContinuousClock.Instant {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        // Frame preparation must not consume the interval before the next send.
        let startedAt = ContinuousClock.now
        try await socket.send(message)
        return startedAt
    }

    private func report(_ error: Error) async {
        guard isRunning, !isTranscriptionPaused else { return }
        // Idle preparation failures never become recognition/call errors and
        // do not prepare again until the next speech onset/listening boundary.
        if !hasDetectedSpeech { closeRecognitionSession(); return }
        // A peer's idle close can race with speech onset. Retry the captured
        // audio once, only if the reused socket has not sent any audio yet.
        if reusedPreconnection, sentAudioBytes == 0 {
            let replay = replayBuffer.audio
            do { try openRecognitionSession(replay: replay, containsSpeech: true, preserveUtterance: true); return }
            catch { await fail(error); return }
        }
        await fail(error)
    }

    private func fail(_ error: Error) async {
        guard isRunning else { return }
        requestLog?.fail(error); requestLog?.finish()
        let handler = onError
        stop()
        await handler?(error)
    }

    private func signedURL() -> URL? {
        let host = "iat-api.xfyun.cn"
        let path = "/v2/iat"
        let date = DateFormatter.xunfeiDate.string(from: Date())
        let requestLine = "GET \(path) HTTP/1.1"
        let signatureOrigin = "host: \(host)\ndate: \(date)\n\(requestLine)"
        let digest = HMAC<SHA256>.authenticationCode(for: Data(signatureOrigin.utf8), using: SymmetricKey(data: Data(credentials.xunfeiAPISecret.utf8)))
        let signature = Data(digest).base64EncodedString()
        let authOrigin = "api_key=\"\(credentials.xunfeiAPIKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\""
        guard let auth = authOrigin.data(using: .utf8)?.base64EncodedString() else { return nil }
        var components = URLComponents(string: "wss://\(host)\(path)")
        components?.queryItems = [URLQueryItem(name: "authorization", value: auth), URLQueryItem(name: "date", value: date), URLQueryItem(name: "host", value: host)]
        return components?.url
    }
}

private extension DateFormatter {
    static let xunfeiDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter
    }()
}
